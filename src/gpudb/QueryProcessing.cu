#include "QueryProcessing.h"
#include "CacheManager.h"
#include "QueryOptimizer.h"
#include "CPUGPUProcessing.h"
// #include "common.h"

int queries[13] = {11, 12, 13, 21, 22, 23, 31, 32, 33, 34, 41, 42, 43};

void
QueryProcessing::executeTableDimNP(int table_id, int sg) {
    int *h_off_col = NULL, *d_off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;

    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    if (sg == 0 || sg == 1) {

      if (qo->joinCPUcheck[table_id] && qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_CPU(params, h_off_col, h_total, sg, table_id);
        cgp->switch_device_dim(d_off_col, h_off_col, d_total, h_total, sg, 0, table_id, streams[sg]);
        cgp->call_build_GPU(params, d_off_col, h_total, sg, table_id, streams[sg]);
        cgp->call_build_CPU(params, h_off_col, h_total, sg, table_id);
      } else if (qo->joinCPUcheck[table_id] && !(qo->joinGPUcheck[table_id])) {
        cgp->call_bfilter_CPU(params, h_off_col, h_total, sg, table_id);
        cgp->call_build_CPU(params, h_off_col, h_total, sg, table_id);
      } else if (!(qo->joinCPUcheck[table_id]) && qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_CPU(params, h_off_col, h_total, sg, table_id);
        cgp->switch_device_dim(d_off_col, h_off_col, d_total, h_total, sg, 0, table_id, streams[sg]);
        cgp->call_build_GPU(params, d_off_col, h_total, sg, table_id, streams[sg]);            
      }

    } else if (sg == 2 || sg == 3) {

      if (qo->joinCPUcheck[table_id]) {
        cgp->call_bfilter_CPU(params, h_off_col, h_total, sg, table_id);
        cgp->call_build_CPU(params, h_off_col, h_total, sg, table_id);
      }

      if (qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_GPU(params, d_off_col, d_total, h_total, sg, table_id, streams[sg]);
        cgp->call_build_GPU(params, d_off_col, h_total, sg, table_id, streams[sg]);  
      }
      
    } else {
      assert(0);
    }
}

void
QueryProcessing::executeTableFactNP(int sg) {
    int** h_off_col = NULL, **off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;

    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    for (int i = 0; i < qo->selectCPUPipelineCol[sg].size(); i++) {
      cgp->call_pfilter_CPUNP(params, h_off_col, h_total, sg, qo->selectCPUPipelineCol[sg][i]);
    }

    if (qo->selectCPUPipelineCol[sg].size() > 0 && (qo->joinGPUPipelineCol[sg].size() > 0 || qo->selectGPUPipelineCol[sg].size() > 0))  
      cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);

    for (int i = 0; i < qo->selectGPUPipelineCol[sg].size(); i++) {
      cgp->call_pfilter_GPUNP(params, off_col, d_total, h_total, sg, streams[sg], qo->selectGPUPipelineCol[sg][i]);
    }

    for (int i = 0; i < qo->joinGPUPipelineCol[sg].size(); i++) {
      cgp->call_probe_GPUNP(params, off_col, d_total, h_total, sg, streams[sg], qo->joinGPUPipelineCol[sg][i]);
    }

    if ((qo->selectGPUPipelineCol[sg].size() > 0 || qo->joinGPUPipelineCol[sg].size() > 0) && (qo->joinCPUPipelineCol[sg].size() > 0 || qo->groupbyCPUPipelineCol[sg].size() > 0))
      cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);

    for (int i = 0; i < qo->joinCPUPipelineCol[sg].size(); i++) {
      cgp->call_probe_CPUNP(params, h_off_col, h_total, sg, qo->joinCPUPipelineCol[sg][i]);
    }

    if (qo->groupbyGPUPipelineCol[sg].size() > 0) {
      if (qo->joinCPUPipelineCol[sg].size() > 0) {
        if (qo->groupby_build.size() == 0) {
          cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          if (!custom) cudaFreeHost(h_off_col[4]);
        } else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);
      } else {
        if (qo->groupby_build.size() == 0) {
          cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]);
          if (!custom) cudaFree(off_col[4]);
        } else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);
      }
    } else {
      if (qo->groupby_build.size() == 0) {
        cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
        if (!custom) cudaFreeHost(h_off_col[4]);
      } else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);
    }
}

void
QueryProcessing::executeTableDim(int table_id, int sg) {
    int *h_off_col = NULL, *d_off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;
    cudaEvent_t start, stop; cudaEventCreate(&start); cudaEventCreate(&stop);
    float time;
    cudaEventRecord(start, 0);
    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    // cout << "dim " << sg << endl;

    if (sg == 0 || sg == 1) {
      cout << qo->joinCPUcheck[table_id] <<" "<< qo->joinGPUcheck[table_id]<<" 123 line in QP.cu\n";
      if (qo->joinCPUcheck[table_id] && qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_CPU(params, h_off_col, h_total, sg, table_id);
        cgp->switch_device_dim(d_off_col, h_off_col, d_total, h_total, sg, 0, table_id, streams[sg]);
        cgp->call_build_GPU(params, d_off_col, h_total, sg, table_id, streams[sg]);
        cgp->call_build_CPU(params, h_off_col, h_total, sg, table_id);
      } else if (qo->joinCPUcheck[table_id] && !(qo->joinGPUcheck[table_id])) {
        cgp->call_bfilter_build_CPU(params, h_off_col, h_total, sg, table_id);
      } else if (!(qo->joinCPUcheck[table_id]) && qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_CPU(params, h_off_col, h_total, sg, table_id);
        cgp->switch_device_dim(d_off_col, h_off_col, d_total, h_total, sg, 0, table_id, streams[sg]);
        cgp->call_build_GPU(params, d_off_col, h_total, sg, table_id, streams[sg]);            
      }

    } else if (sg == 2 || sg == 3) {

      if (qo->joinCPUcheck[table_id]) {
        cgp->call_bfilter_build_CPU(params, h_off_col, h_total, sg, table_id);
      }

      if (qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_build_GPU(params, d_off_col, h_total, sg, table_id, streams[sg]);
      }
      
    } else {
      assert(0);
    }
     cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&time, start, stop);
    cout<< "executeTableDim time taken: "<<time<<"\n";
}

void
QueryProcessing::executeTableDim_HE(int table_id, int segment_idx) {
    int *h_off_col = NULL, *d_off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;

    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    // cout << "dim " << segment_idx << endl;

    int sg = qo->index_to_sg[table_id][segment_idx];

    if (sg == 0 || sg == 1) {

      if (qo->joinCPUcheck[table_id] && qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_CPUHE(params, h_off_col, h_total, segment_idx, table_id);
        cgp->switch_device_dim(d_off_col, h_off_col, d_total, h_total, segment_idx, 0, table_id, streams[segment_idx]);
        cgp->call_build_GPUHE(params, d_off_col, h_total, segment_idx, table_id, streams[segment_idx]);
        cgp->call_build_CPUHE(params, h_off_col, h_total, segment_idx, table_id);
      } else if (qo->joinCPUcheck[table_id] && !(qo->joinGPUcheck[table_id])) {
        cgp->call_bfilter_build_CPUHE(params, h_off_col, h_total, segment_idx, table_id);
      } else if (!(qo->joinCPUcheck[table_id]) && qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_CPUHE(params, h_off_col, h_total, segment_idx, table_id);
        cgp->switch_device_dim(d_off_col, h_off_col, d_total, h_total, segment_idx, 0, table_id, streams[segment_idx]);
        cgp->call_build_GPUHE(params, d_off_col, h_total, segment_idx, table_id, streams[segment_idx]);            
      }

    } else if (sg == 2 || sg == 3) {

      if (qo->joinCPUcheck[table_id]) {
        cgp->call_bfilter_build_CPUHE(params, h_off_col, h_total, segment_idx, table_id);
      }

      if (qo->joinGPUcheck[table_id]) {
        cgp->call_bfilter_build_GPUHE(params, d_off_col, h_total, segment_idx, table_id, streams[segment_idx]);
      }
      
    } else {
      assert(0);
    }

}

void
QueryProcessing::executeTableFact_v1(int sg) {
    int** h_off_col = NULL, **off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;

    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    // printf("fact sg = %d\n", sg);
    //cout<<qo->selectCPUPipelineCol[sg].size()<<" "<<qo->selectGPUPipelineCol[sg].size()<<" "<<qo->joinGPUPipelineCol[sg].size()<<" "<<qo->joinCPUPipelineCol[sg].size()<<" "<<qo->groupbyGPUPipelineCol[sg].size()<<" check values\n";
    if (qo->selectCPUPipelineCol[sg].size() > 0) {
      if (qo->selectGPUPipelineCol[sg].size() > 0 && qo->joinGPUPipelineCol[sg].size() > 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_GPU(params, off_col, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]); 
          else cgp->call_pfilter_probe_group_by_GPU(params, off_col, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg); 
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        }
      } else if (qo->selectGPUPipelineCol[sg].size() == 0 && qo->joinGPUPipelineCol[sg].size() > 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]); 
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);          

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg); 
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        }
      } else if (qo->selectGPUPipelineCol[sg].size() > 0 && qo->joinGPUPipelineCol[sg].size() == 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, qo->selectCPUPipelineCol[sg].size(), streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        }
      } else if (qo->selectGPUPipelineCol[sg].size() == 0 && qo->joinGPUPipelineCol[sg].size() == 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_CPU(params, h_off_col, h_total, sg, 0);
          else cgp->call_pfilter_probe_group_by_CPU(params, h_off_col, h_total, sg, 0);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        }   
      }
    } else {
      if (qo->selectGPUPipelineCol[sg].size() > 0 && qo->joinGPUPipelineCol[sg].size() > 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_GPU(params, off_col, h_total, sg, 0, streams[sg]);
          else cgp->call_pfilter_probe_group_by_GPU(params, off_col, h_total, sg, 0, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg); 
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        }
      } else if (qo->selectGPUPipelineCol[sg].size() == 0 && qo->joinGPUPipelineCol[sg].size() > 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]); 
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);   

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg); 
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        }
      } else if (qo->selectGPUPipelineCol[sg].size() > 0 && qo->joinGPUPipelineCol[sg].size() == 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        }
      } else if (qo->selectGPUPipelineCol[sg].size() == 0 && qo->joinGPUPipelineCol[sg].size() == 0) {
        if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]); 
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinCPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg); 
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinCPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        }   
      }
    }
}

void
QueryProcessing::executeTableFact_HE(int segment_idx) {
    int** h_off_col = NULL, **off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;

    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    // printf("fact segment_idx = %d\n", segment_idx);

    if (qo->selectCPUPipelineCol[segment_idx].size() > 0) {
      if (qo->selectGPUPipelineCol[segment_idx].size() > 0 && qo->joinGPUPipelineCol[segment_idx].size() > 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_GPUHE(params, off_col, h_total, segment_idx, qo->selectCPUPipelineCol[segment_idx].size(), streams[segment_idx]); 

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_pfilter_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, qo->selectCPUPipelineCol[segment_idx].size(), streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_pfilter_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, qo->selectCPUPipelineCol[segment_idx].size(), streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_pfilter_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, qo->selectCPUPipelineCol[segment_idx].size(), streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPUHE(params, h_off_col[0], h_total, segment_idx); 
          else cgp->call_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        }
      } else if (qo->selectGPUPipelineCol[segment_idx].size() == 0 && qo->joinGPUPipelineCol[segment_idx].size() > 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_probe_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);          

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPUHE(params, h_off_col[0], h_total, segment_idx); 
          else cgp->call_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        }
      } else if (qo->selectGPUPipelineCol[segment_idx].size() > 0 && qo->joinGPUPipelineCol[segment_idx].size() == 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_pfilter_GPUHE(params, off_col, d_total, h_total, segment_idx, qo->selectCPUPipelineCol[segment_idx].size(), streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          cgp->call_pfilter_GPUHE(params, off_col, d_total, h_total, segment_idx, qo->selectCPUPipelineCol[segment_idx].size(), streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {
          assert(0);
        }
      } else if (qo->selectGPUPipelineCol[segment_idx].size() == 0 && qo->joinGPUPipelineCol[segment_idx].size() == 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_probe_CPUHE(params, h_off_col, h_total, segment_idx, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx, 0);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {
          assert(0);
        }   
      }
    } else {
      if (qo->selectGPUPipelineCol[segment_idx].size() > 0 && qo->joinGPUPipelineCol[segment_idx].size() > 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_GPUHE(params, off_col, h_total, segment_idx, 0, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, 0, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, 0, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, 0, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPUHE(params, h_off_col[0], h_total, segment_idx); 
          else cgp->call_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        }
      } else if (qo->selectGPUPipelineCol[segment_idx].size() == 0 && qo->joinGPUPipelineCol[segment_idx].size() > 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_probe_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);   

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_probe_GPUHE(params, off_col, d_total, h_total, segment_idx, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPUHE(params, h_off_col[0], h_total, segment_idx); 
          else cgp->call_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        }
      } else if (qo->selectGPUPipelineCol[segment_idx].size() > 0 && qo->joinGPUPipelineCol[segment_idx].size() == 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_pfilter_GPUHE(params, off_col, d_total, h_total, segment_idx, 0, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {

          cgp->call_pfilter_GPUHE(params, off_col, d_total, h_total, segment_idx, 0, streams[segment_idx]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 1, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {
          assert(0);
        }
      } else if (qo->selectGPUPipelineCol[segment_idx].size() == 0 && qo->joinGPUPipelineCol[segment_idx].size() == 0) {
        if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {
          assert(0);
        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() > 0) {

          cgp->call_probe_CPUHE(params, h_off_col, h_total, segment_idx);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, segment_idx, 0, 0, streams[segment_idx]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPUHE(params, off_col[0], h_total, segment_idx, streams[segment_idx]); 
          else cgp->call_group_by_GPUHE(params, off_col, h_total, segment_idx, streams[segment_idx]);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() > 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPUHE(params, h_off_col, h_total, segment_idx); 
          else cgp->call_probe_group_by_CPUHE(params, h_off_col, h_total, segment_idx);

        } else if (qo->joinCPUPipelineCol[segment_idx].size() == 0 && qo->groupbyGPUPipelineCol[segment_idx].size() == 0) {
          assert(0);
        }   
      }
    }
}

void
QueryProcessing::executeTableFact_v2(int sg) {
    int** h_off_col = NULL, **off_col = NULL;
    int* d_total = NULL;
    int* h_total = NULL;

    if (custom) h_total = (int*) cm->customCudaHostAlloc<int>(1);
    else CubDebugExit(cudaHostAlloc((void**) &h_total, 1 * sizeof(int), cudaHostAllocDefault));
    memset(h_total, 0, sizeof(int));
    if (custom) d_total = (int*) cm->customCudaMalloc<int>(1);
    else CubDebugExit(cudaMalloc((void**) &d_total, 1 * sizeof(int)));

    if (verbose) printf("sg = %d\n", sg);

    if (qo->selectGPUPipelineCol[sg].size() > 0) {
      if (qo->selectCPUPipelineCol[sg].size() > 0 && qo->joinCPUPipelineCol[sg].size() > 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());
          else cgp->call_pfilter_probe_group_by_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]);
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        }
      } else if (qo->selectCPUPipelineCol[sg].size() == 0 && qo->joinCPUPipelineCol[sg].size() > 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg);
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]);
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        }
      } else if (qo->selectCPUPipelineCol[sg].size() > 0 && qo->joinCPUPipelineCol[sg].size() == 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, qo->selectGPUPipelineCol[sg].size());
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        }
      } else if (qo->selectCPUPipelineCol[sg].size() == 0 && qo->joinCPUPipelineCol[sg].size() == 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_probe_GPU(params, off_col, d_total, h_total, sg, 0, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_GPU(params, off_col, h_total, sg, 0, streams[sg]);
          else cgp->call_pfilter_probe_group_by_GPU(params, off_col, h_total, sg, 0, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        }
      }
    } else {
      if (qo->selectCPUPipelineCol[sg].size() > 0 && qo->joinCPUPipelineCol[sg].size() > 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          if (qo->groupby_build.size() == 0) cgp->call_pfilter_probe_aggr_CPU(params, h_off_col, h_total, sg, 0);
          else cgp->call_pfilter_probe_group_by_CPU(params, h_off_col, h_total, sg, 0);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_probe_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]);
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        }
      } else if (qo->selectCPUPipelineCol[sg].size() == 0 && qo->joinCPUPipelineCol[sg].size() > 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_CPU(params, h_off_col, h_total, sg);
          else cgp->call_probe_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_probe_CPU(params, h_off_col, h_total, sg);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_GPU(params, off_col[0], h_total, sg, streams[sg]);
          else cgp->call_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        }
      } else if (qo->selectCPUPipelineCol[sg].size() > 0 && qo->joinCPUPipelineCol[sg].size() == 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          cgp->call_pfilter_CPU(params, h_off_col, h_total, sg, 0);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 0, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        }
      } else if (qo->selectCPUPipelineCol[sg].size() == 0 && qo->joinCPUPipelineCol[sg].size() == 0) {
        if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {
          assert(0);
        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() == 0) {

          cgp->call_probe_GPU(params, off_col, d_total, h_total, sg, streams[sg]);
          cgp->switch_device_fact(off_col, h_off_col, d_total, h_total, sg, 1, 0, streams[sg]);
          if (qo->groupby_build.size() == 0) cgp->call_aggregation_CPU(params, h_off_col[0], h_total, sg);
          else cgp->call_group_by_CPU(params, h_off_col, h_total, sg);

        } else if (qo->joinGPUPipelineCol[sg].size() > 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {

          if (qo->groupby_build.size() == 0) cgp->call_probe_aggr_GPU(params, off_col, h_total, sg, streams[sg]);
          else cgp->call_probe_group_by_GPU(params, off_col, h_total, sg, streams[sg]);

        } else if (qo->joinGPUPipelineCol[sg].size() == 0 && qo->groupbyGPUPipelineCol[sg].size() > 0) {
          assert(0);
        }
      }
    }
}

void
QueryProcessing::executeTableDimOD(int table_id, int sg) {
    int tile_items = 128 * 4;
    int count_segment = qo->segment_group_count[table_id][sg];
    int total_segment = cm->allColumn[cm->columns_in_table[table_id][0]]->total_segment;
    int LEN = cm->allColumn[cm->columns_in_table[table_id][0]]->LEN;

    int total_batch = (count_segment + OD_BATCH_SIZE - 1)/OD_BATCH_SIZE;
    int last_batch;
    if (count_segment % OD_BATCH_SIZE == 0) last_batch = OD_BATCH_SIZE;
    else last_batch = count_segment % OD_BATCH_SIZE;

    ColumnInfo *key;
    for (int i = 0; i < qo->join.size(); i++) {
      if (qo->join[i].second->table_id == table_id) key = qo->join[i].second;
    }

    ColumnInfo *val = NULL, *filter = NULL;

    if (qo->groupby_build.size() > 0 && qo->groupby_build[key].size() > 0) {
      val = qo->groupby_build[key][0];
    }

    if (qo->select_build[key].size() > 0) {
      filter = qo->select_build[key][0];
    }

    short* segment_group_ptr = qo->segment_group[table_id] + (sg * total_segment);

    for (int j = 0; j < total_batch; j++) {
      int batch_size;
      if (j == total_batch-1) batch_size = last_batch;
      else batch_size = OD_BATCH_SIZE;

      parallel_for(int(0), batch_size, [=](int batch){
          CubDebugExit(cudaStreamCreate(&streams[batch]));

          int segment_number = (j * OD_BATCH_SIZE + batch);
          assert(segment_number < qo->segment_group_count[table_id][sg]);
          int segment_idx = segment_group_ptr[segment_number];
          assert(segment_idx < key->total_segment);

          int num_tuples;
          if (LEN % SEGMENT_SIZE != 0 && segment_idx == total_segment-1) num_tuples = LEN % SEGMENT_SIZE;
          else num_tuples = SEGMENT_SIZE;

          int* key_ptr = NULL, *val_ptr = NULL, *filter_ptr = NULL;

          if (key != NULL) {
            if (cm->segment_bitmap[key->column_id][segment_idx] == 0) {
              key_ptr = cm->onDemandTransfer(key->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
            } else {
              key_ptr = cm->gpuCache + cm->segment_list[key->column_id][segment_idx] * SEGMENT_SIZE;
            }
          }

          if (val != NULL) {
            if (cm->segment_bitmap[val->column_id][segment_idx] == 0) {
              val_ptr = cm->onDemandTransfer(val->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
            } else {
              val_ptr = cm->gpuCache + cm->segment_list[val->column_id][segment_idx] * SEGMENT_SIZE;
            }
          }

          if (filter != NULL) {
            if (cm->segment_bitmap[filter->column_id][segment_idx] == 0) {
              filter_ptr = cm->onDemandTransfer(filter->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
            } else {
              filter_ptr = cm->gpuCache + cm->segment_list[filter->column_id][segment_idx] * SEGMENT_SIZE;
            }
          }

          build_GPU<128,4><<<(num_tuples+ tile_items - 1)/tile_items, 128, 0, streams[batch]>>>(
            key_ptr, val_ptr, filter_ptr, params->compare1[filter], params->compare2[filter], params->map_filter_func_dev[filter],
            num_tuples, params->ht_GPU[key], params->dim_len[key], params->min_key[key], segment_idx);

          CHECK_ERROR_STREAM(streams[batch]);

          CubDebugExit(cudaStreamSynchronize(streams[batch]));
          CubDebugExit(cudaStreamDestroy(streams[batch]));
      });

    }
}

void
QueryProcessing::executeTableFactOD(int sg) {
    int tile_items = 128 * 4;
    int table_id = cm->lo_orderdate->table_id;
    int count_segment = qo->segment_group_count[table_id][sg];
    int total_segment = cm->allColumn[cm->columns_in_table[table_id][0]]->total_segment;
    int LEN = cm->allColumn[cm->columns_in_table[table_id][0]]->LEN;

    int total_batch = (count_segment + OD_BATCH_SIZE - 1)/OD_BATCH_SIZE;
    int last_batch;
    if (count_segment % OD_BATCH_SIZE == 0) last_batch = OD_BATCH_SIZE;
    else last_batch = count_segment % OD_BATCH_SIZE;

    if (qo->groupby_build.size() == 0) {

      ColumnInfo *pkey[4] = {}, *fkey[4] = {}, *aggr[2] = {}, *filter[2] = {};

      for (int i = 0; i < qo->select_probe[cm->lo_orderdate].size(); i++) {
        filter[i] = qo->select_probe[cm->lo_orderdate][i];
      }

      for (int i = 0; i < qo->join.size(); i++) {
        int table_id = qo->join[i].second->table_id;
        fkey[table_id - 1] = qo->join[i].first;
        pkey[table_id - 1] = qo->join[i].second;
      }

      for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
        aggr[i] = qo->aggregation[cm->lo_orderdate][i];
      }

      for (int j = 0; j < total_batch; j++) {
        int batch_size;
        if (j == total_batch-1) batch_size = last_batch;
        else batch_size = OD_BATCH_SIZE;

        short* segment_group_ptr = qo->segment_group[0] + (sg * cm->lo_orderdate->total_segment);

        parallel_for(int(0), batch_size, [=](int batch){

            CubDebugExit(cudaStreamCreate(&streams[batch]));
            int segment_number = (j * OD_BATCH_SIZE + batch);
            assert(segment_number < qo->segment_group_count[0][sg]);
            int segment_idx = segment_group_ptr[segment_number];
            assert(segment_idx < cm->lo_orderdate->total_segment);

            int* d_key[4] = {}, *d_aggr[2] = {}, *d_filter[2] = {};

            int num_tuples;
            if (cm->lo_orderdate->LEN % SEGMENT_SIZE != 0 && segment_idx == cm->lo_orderdate->total_segment-1) {
              num_tuples = cm->lo_orderdate->LEN % SEGMENT_SIZE;
            } else {
              num_tuples = SEGMENT_SIZE;
            }

            for (int i = 0; i < qo->select_probe[cm->lo_orderdate].size(); i++) {
              if (filter[i] != NULL) {
                if (cm->segment_bitmap[filter[i]->column_id][segment_idx] == 0) {
                  d_filter[i] = cm->onDemandTransfer(filter[i]->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
                } else {
                  d_filter[i] = cm->gpuCache + cm->segment_list[filter[i]->column_id][segment_idx] * SEGMENT_SIZE;
                }
              }
            }

            for (int i = 0; i < qo->join.size(); i++) {
              if (fkey[i] != NULL) {
                if (cm->segment_bitmap[fkey[i]->column_id][segment_idx] == 0) {
                  d_key[i] = cm->onDemandTransfer(fkey[i]->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
                } else {
                  d_key[i] = cm->gpuCache + cm->segment_list[fkey[i]->column_id][segment_idx] * SEGMENT_SIZE;
                }
              }
            }

            for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
              if (aggr[i] != NULL) {
                if (cm->segment_bitmap[aggr[i]->column_id][segment_idx] == 0) {
                  d_aggr[i] = cm->onDemandTransfer(aggr[i]->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
                } else {
                  d_aggr[i] = cm->gpuCache + cm->segment_list[aggr[i]->column_id][segment_idx] * SEGMENT_SIZE;
                }
              }
            }

            filter_probe_aggr_GPU<128, 4><<<(num_tuples + tile_items - 1)/tile_items, 128, 0, streams[batch]>>>(
              d_filter[0], d_filter[1], params->compare1[filter[0]], params->compare2[filter[0]], params->compare1[filter[1]], params->compare2[filter[1]],
              params->map_filter_func_dev[filter[0]], params->map_filter_func_dev[filter[1]],
              d_key[3], params->ht_GPU[pkey[3]], params->dim_len[pkey[3]], params->min_key[pkey[3]],
              d_aggr[0], d_aggr[1], params->d_group_func, 
              num_tuples, params->d_res);

            CHECK_ERROR_STREAM(streams[batch]);

            CubDebugExit(cudaStreamSynchronize(streams[batch]));
            CubDebugExit(cudaStreamDestroy(streams[batch]));

        });

      } 

    } else {

      ColumnInfo *pkey[4] = {}, *fkey[4] = {}, *aggr[2] = {};

      for (int i = 0; i < qo->join.size(); i++) {
        int table_id = qo->join[i].second->table_id;
        fkey[table_id - 1] = qo->join[i].first;
        pkey[table_id - 1] = qo->join[i].second;
      }

      for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
        aggr[i] = qo->aggregation[cm->lo_orderdate][i];
      }

      for (int j = 0; j < total_batch; j++) {

        int batch_size;
        if (j == total_batch-1) batch_size = last_batch;
        else batch_size = OD_BATCH_SIZE;

        short* segment_group_ptr = qo->segment_group[0] + (sg * cm->lo_orderdate->total_segment);

        // for (int batch = 0; batch < batch_size; batch++) {
        parallel_for(int(0), batch_size, [=](int batch){

            CubDebugExit(cudaStreamCreate(&streams[batch]));
            int segment_number = (j * OD_BATCH_SIZE + batch);
            assert(segment_number < qo->segment_group_count[0][sg]);
            int segment_idx = segment_group_ptr[segment_number];
            assert(segment_idx < cm->lo_orderdate->total_segment);

            int* d_key[4] = {}, *d_aggr[2] = {};

            int num_tuples;
            if (cm->lo_orderdate->LEN % SEGMENT_SIZE != 0 && segment_idx == cm->lo_orderdate->total_segment-1) {
              num_tuples = cm->lo_orderdate->LEN % SEGMENT_SIZE;
            } else {
              num_tuples = SEGMENT_SIZE;
            }

            for (int i = 0; i < qo->join.size(); i++) {
              if (fkey[i] != NULL) {
                if (cm->segment_bitmap[fkey[i]->column_id][segment_idx] == 0) {
                  d_key[i] = cm->onDemandTransfer(fkey[i]->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
                } else {
                  d_key[i] = cm->gpuCache + cm->segment_list[fkey[i]->column_id][segment_idx] * SEGMENT_SIZE;
                }
              }
            }

            for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
              if (aggr[i] != NULL) {
                if (cm->segment_bitmap[aggr[i]->column_id][segment_idx] == 0) {
                  d_aggr[i] = cm->onDemandTransfer(aggr[i]->col_ptr + segment_idx * SEGMENT_SIZE, num_tuples, streams[batch]);
                } else {
                  d_aggr[i] = cm->gpuCache + cm->segment_list[aggr[i]->column_id][segment_idx] * SEGMENT_SIZE;
                }
              }
            }

            probe_group_by_GPU<128, 4><<<(num_tuples + tile_items - 1)/tile_items, 128, 0, streams[batch]>>>(
              d_key[0], d_key[1], d_key[2], d_key[3], 
              params->ht_GPU[pkey[0]], params->dim_len[pkey[0]], params->ht_GPU[pkey[1]], params->dim_len[pkey[1]], params->ht_GPU[pkey[2]], params->dim_len[pkey[2]], params->ht_GPU[pkey[3]], params->dim_len[pkey[3]],
              params->min_key[pkey[0]], params->min_key[pkey[1]], params->min_key[pkey[2]], params->min_key[pkey[3]],
              d_aggr[0], d_aggr[1],
              params->min_val[pkey[0]], params->min_val[pkey[1]], params->min_val[pkey[2]], params->min_val[pkey[3]],
              params->unique_val[pkey[0]], params->unique_val[pkey[1]], params->unique_val[pkey[2]], params->unique_val[pkey[3]],
              params->total_val, params->d_group_func,
              num_tuples, params->d_res);

            CHECK_ERROR_STREAM(streams[batch]);

            CubDebugExit(cudaStreamSynchronize(streams[batch]));
            CubDebugExit(cudaStreamDestroy(streams[batch]));

        });
        // }


      }
    }

    CubDebugExit(cudaMemcpy(params->res, params->d_res, params->total_val * 6 * sizeof(int), cudaMemcpyDeviceToHost));
    cgp->gpu_to_cpu_total += (params->total_val * 6 * sizeof(int));

}

void
QueryProcessing::executeTableFactOD2(int sg) {

    int table_id = cm->lo_orderdate->table_id;
    int count_segment = qo->segment_group_count[table_id][sg];
    int total_segment = cm->allColumn[cm->columns_in_table[table_id][0]]->total_segment;
    int LEN = cm->allColumn[cm->columns_in_table[table_id][0]]->LEN;

    int total_batch = (count_segment + OD_BATCH_SIZE - 1)/OD_BATCH_SIZE;
    int last_batch;
    if (count_segment % OD_BATCH_SIZE == 0) last_batch = OD_BATCH_SIZE;
    else last_batch = count_segment % OD_BATCH_SIZE;

    if (qo->groupby_build.size() == 0) {

      ColumnInfo *pkey[4] = {}, *fkey[4] = {}, *aggr[2] = {}, *filter[2] = {};

      for (int i = 0; i < qo->select_probe[cm->lo_orderdate].size(); i++) {
        filter[i] = qo->select_probe[cm->lo_orderdate][i];
      }

      for (int i = 0; i < qo->join.size(); i++) {
        int table_id = qo->join[i].second->table_id;
        fkey[table_id - 1] = qo->join[i].first;
        pkey[table_id - 1] = qo->join[i].second;
      }

      for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
        aggr[i] = qo->aggregation[cm->lo_orderdate][i];
      }

      for (int j = 0; j < total_batch; j++) {
        int batch_size;
        if (j == total_batch-1) batch_size = last_batch;
        else batch_size = OD_BATCH_SIZE;

        short* segment_group_ptr = qo->segment_group[0] + (sg * cm->lo_orderdate->total_segment);

        // parallel_for(int(0), batch_size, [=](int batch){
        for (int batch = 0; batch < batch_size; batch++) {

            // cudaStream_t stream;

            // CubDebugExit(cudaStreamCreate(&stream));
            int segment_number = (j * OD_BATCH_SIZE + batch);
            assert(segment_number < qo->segment_group_count[0][sg]);
            int segment_idx = segment_group_ptr[segment_number];

            // cout << segment_idx << endl;

            int num_tuples;
            if (cm->lo_orderdate->LEN % SEGMENT_SIZE != 0 && segment_idx == cm->lo_orderdate->total_segment-1) {
              num_tuples = cm->lo_orderdate->LEN % SEGMENT_SIZE;
            } else {
              num_tuples = SEGMENT_SIZE;
            }

            for (int i = 0; i < qo->select_probe[cm->lo_orderdate].size(); i++) {
              if (filter[i] != NULL) {
                cm->onDemandTransfer2(filter[i], segment_idx, num_tuples, streams[sg]);
              }
            }

            for (int i = 0; i < qo->join.size(); i++) {
              int table_id = qo->join[i].second->table_id;
              if (fkey[table_id - 1] != NULL) {
                cm->onDemandTransfer2(fkey[table_id - 1], segment_idx, num_tuples, streams[sg]);
              }
            }

            for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
              if (aggr[i] != NULL) {
                cm->onDemandTransfer2(aggr[i], segment_idx, num_tuples, streams[sg]);
              }
            }

            // CubDebugExit(cudaStreamSynchronize(streams[sg]));
            // CubDebugExit(cudaStreamDestroy(stream));

        // });
        }

        // CubDebugExit(cudaStreamSynchronize(streams[sg]));
        cgp->call_pfilter_probe_aggr_OD(params, filter, pkey, fkey, aggr, sg, j, batch_size, total_batch, streams[sg]);
      }

    } else {

      ColumnInfo *pkey[4] = {}, *fkey[4] = {}, *aggr[2] = {};

      for (int i = 0; i < qo->join.size(); i++) {
        int table_id = qo->join[i].second->table_id;
        fkey[table_id - 1] = qo->join[i].first;
        pkey[table_id - 1] = qo->join[i].second;
      }

      for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
        aggr[i] = qo->aggregation[cm->lo_orderdate][i];
      }

      cout << sg << endl;

      for (int j = 0; j < total_batch; j++) {

        int batch_size;
        if (j == total_batch-1) batch_size = last_batch;
        else batch_size = OD_BATCH_SIZE;

        short* segment_group_ptr = qo->segment_group[0] + (sg * cm->lo_orderdate->total_segment);

        // parallel_for(int(0), batch_size, [=](int batch){
        for (int batch = 0; batch < batch_size; batch++) {

            // cudaStream_t stream;

            // CubDebugExit(cudaStreamCreate(&stream));
            int segment_number = (j * OD_BATCH_SIZE + batch);
            assert(segment_number < qo->segment_group_count[0][sg]);
            int segment_idx = segment_group_ptr[segment_number];
            assert(segment_idx < cm->lo_orderdate->total_segment);

            // cout << segment_idx << endl;

            int num_tuples;
            if (cm->lo_orderdate->LEN % SEGMENT_SIZE != 0 && segment_idx == cm->lo_orderdate->total_segment-1) {
              num_tuples = cm->lo_orderdate->LEN % SEGMENT_SIZE;
            } else {
              num_tuples = SEGMENT_SIZE;
            }

            for (int i = 0; i < qo->join.size(); i++) {
              int table_id = qo->join[i].second->table_id;
              if (fkey[table_id - 1] != NULL) {
                cm->onDemandTransfer2(fkey[table_id - 1], segment_idx, num_tuples, streams[sg]);
              }
            }

            for (int i = 0; i < qo->aggregation[cm->lo_orderdate].size(); i++) {
              if (aggr[i] != NULL) {
                cm->onDemandTransfer2(aggr[i], segment_idx, num_tuples, streams[sg]);
              }
            }

            // CubDebugExit(cudaStreamSynchronize(streams[sg]));
            // CubDebugExit(cudaStreamDestroy(stream));

        // });
        }

        // CubDebugExit(cudaStreamSynchronize(streams[sg]));
        cgp->call_probe_group_by_OD(params, pkey, fkey, aggr, sg, j, batch_size, total_batch, streams[sg]);
      }

    }

}

void
QueryProcessing::runQuery(CUcontext ctx) {

  SETUP_TIMING();
  float time;
  cudaEventRecord(start, 0);

  for (int i = 0; i < qo->join.size(); i++) {
    int table_id = qo->join[i].second->table_id;

    // for (short j = 0; j < qo->par_segment_count[table_id]; j++) {

    parallel_for(short(0), qo->par_segment_count[table_id], [=](short j){

      CUcontext poppedCtx;
      cuCtxPushCurrent(ctx);

      // cuCtxSetCurrent(ctx);

      int sg = qo->par_segment[table_id][j];

      if (verbose) {
        cout << qo->join[i].second->column_name << endl;
        printf("sg = %d\n", sg);
      }

      CubDebugExit(cudaStreamCreate(&streams[sg]));

      if (qo->segment_group_count[table_id][sg] > 0) {
        executeTableDim(table_id, sg);
      }

      CubDebugExit(cudaStreamSynchronize(streams[sg]));
      CubDebugExit(cudaStreamDestroy(streams[sg]));

      // cuCtxSetCurrent(NULL);

      cuCtxPopCurrent(&poppedCtx);
      // CHECK_CU_ERROR(cuCtxPopCurrent(&poppedCtx), "cuCtxPopCurrent");

    });

    // }

    CubDebugExit(cudaDeviceSynchronize());
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Build time " << time << endl;
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  parallel_for(short(0), qo->par_segment_count[0], [=](short i){

    // cout << i << " of " << qo->par_segment_count[0] << endl;

    CUcontext poppedCtx;
    cuCtxPushCurrent(ctx);

    // cout << i << " of " << qo->par_segment_count[0] << endl;

    // cuCtxSetCurrent(ctx);

  //for (int i = 0; i < qo->par_segment_count[0]; i++) {
    int sg = qo->par_segment[0][i];

    CubDebugExit(cudaStreamCreate(&streams[sg]));

    float time_;
    cudaEvent_t start_, stop_; 
    cudaEventCreate(&start_); cudaEventCreate(&stop_);
    cudaEventRecord(start_, 0);

    if (qo->segment_group_count[0][sg] > 0) {
      executeTableFact_v1(sg);
    }

    cudaEventRecord(stop_, 0);
    cudaEventSynchronize(stop_);
    cudaEventElapsedTime(&time_, start_, stop_);

    if (verbose) cout << "sg = " << sg << " non demand time = " << time_ << endl;

    CubDebugExit(cudaStreamSynchronize(streams[sg]));
    CubDebugExit(cudaStreamDestroy(streams[sg]));

    cuCtxPopCurrent(&poppedCtx);

  });

  CubDebugExit(cudaDeviceSynchronize());

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Probe time " << time << endl;
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  int* resGPU;
  if (custom) resGPU = (int*) cm->customCudaHostAlloc<int>(params->total_val * 6);
  else CubDebugExit(cudaHostAlloc((void**) &resGPU, params->total_val * 6 * sizeof(int), cudaHostAllocDefault));
  CubDebugExit(cudaMemcpy(resGPU, params->d_res, params->total_val * 6 * sizeof(int), cudaMemcpyDeviceToHost));
  cgp->gpu_to_cpu_total += (params->total_val * 6 * sizeof(int));

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  merge(params->res, resGPU, params->total_val);

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Merge time " << time << endl;
  cgp->merging_total += time;
}



void
QueryProcessing::runQuery2(CUcontext ctx) {

  SETUP_TIMING();
  float time;
  cudaEventRecord(start, 0);

  cudaEvent_t start_, stop_; cudaEventCreate(&start_); cudaEventCreate(&stop_);
    float time_;
    cudaEventRecord(start_, 0);

  cout << qo->join.size() << " join size\n";
  for (int i = 0; i < qo->join.size(); i++) {
    int table_id = qo->join[i].second->table_id;

    // for (short j = 0; j < qo->par_segment_count[table_id]; j++) {

    parallel_for(short(0), qo->par_segment_count[table_id], [=](short j){

      CUcontext poppedCtx;
      cuCtxPushCurrent(ctx);

      int sg = qo->par_segment[table_id][j];

      if (verbose) {
        cout << qo->join[i].second->column_name << endl;
        printf("sg = %d\n", sg);
      }

      CubDebugExit(cudaStreamCreate(&streams[sg]));

      if (qo->segment_group_count[table_id][sg] > 0) {
        executeTableDim(table_id, sg);
      }

      CubDebugExit(cudaStreamSynchronize(streams[sg]));
      CubDebugExit(cudaStreamDestroy(streams[sg]));

      cuCtxPopCurrent(&poppedCtx);
  cudaEventRecord(stop_, 0);
  cudaEventSynchronize(stop_);
  cudaEventElapsedTime(&time_, start_, stop_);
    cout << "find time " << time_ << endl;
    });
    
    // }

    CubDebugExit(cudaDeviceSynchronize());

  
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Build time " << time << endl;
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  parallel_for(short(0), qo->par_segment_count[0], [=](short i){

    CUcontext poppedCtx;
    cuCtxPushCurrent(ctx);

  //for (int i = 0; i < qo->par_segment_count[0]; i++) {
    int sg = qo->par_segment[0][i];

    CubDebugExit(cudaStreamCreate(&streams[sg]));

    float time_;
    cudaEvent_t start_, stop_; 
    cudaEventCreate(&start_); cudaEventCreate(&stop_);
    cudaEventRecord(start_, 0);

    if (qo->segment_group_count[0][sg] > 0) {
      executeTableFact_v2(sg);
    }

    cudaEventRecord(stop_, 0);
    cudaEventSynchronize(stop_);
    cudaEventElapsedTime(&time_, start_, stop_);

    if (verbose) cout << "sg = " << sg << " non demand time = " << time_ << endl;

    CubDebugExit(cudaStreamSynchronize(streams[sg]));
    CubDebugExit(cudaStreamDestroy(streams[sg]));

    cuCtxPopCurrent(&poppedCtx);

  });

  CubDebugExit(cudaDeviceSynchronize());

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Probe time " << time << endl;
  cgp->execution_total += time;
  
  cudaEventRecord(start, 0);

  int* resGPU;
  if (custom) resGPU = (int*) cm->customCudaHostAlloc<int>(params->total_val * 6);
  else CubDebugExit(cudaHostAlloc((void**) &resGPU, params->total_val * 6 * sizeof(int), cudaHostAllocDefault));
  CubDebugExit(cudaMemcpy(resGPU, params->d_res, params->total_val * 6 * sizeof(int), cudaMemcpyDeviceToHost));
  cgp->gpu_to_cpu_total += (params->total_val * 6 * sizeof(int));

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  merge(params->res, resGPU, params->total_val);

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Merge time " << time << endl;
  cgp->merging_total += time;
}

void
QueryProcessing::runQueryNP(CUcontext ctx) {

  SETUP_TIMING();
  float time;
  cudaEventRecord(start, 0);

  for (int i = 0; i < qo->join.size(); i++) {
    int table_id = qo->join[i].second->table_id;

    // for (short j = 0; j < qo->par_segment_count[table_id]; j++) {

    parallel_for(short(0), qo->par_segment_count[table_id], [=](short j){

      CUcontext poppedCtx;
      cuCtxPushCurrent(ctx);

      int sg = qo->par_segment[table_id][j];

      if (verbose) {
        cout << qo->join[i].second->column_name << endl;
        printf("sg = %d\n", sg);
      }

      CubDebugExit(cudaStreamCreate(&streams[sg]));

      if (qo->segment_group_count[table_id][sg] > 0) {
        executeTableDimNP(table_id, sg);
      }

      CubDebugExit(cudaStreamSynchronize(streams[sg]));
      CubDebugExit(cudaStreamDestroy(streams[sg]));

      cuCtxPopCurrent(&poppedCtx);

    });

    CubDebugExit(cudaDeviceSynchronize());
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Build time " << time << endl;
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  parallel_for(short(0), qo->par_segment_count[0], [=](short i){

    CUcontext poppedCtx;
    cuCtxPushCurrent(ctx);

  //for (int i = 0; i < qo->par_segment_count[0]; i++) {
    int sg = qo->par_segment[0][i];

    CubDebugExit(cudaStreamCreate(&streams[sg]));

    float time_;
    cudaEvent_t start_, stop_; 
    cudaEventCreate(&start_); cudaEventCreate(&stop_);
    cudaEventRecord(start_, 0);

    if (qo->segment_group_count[0][sg] > 0) {
      executeTableFactNP(sg);
    }

    cudaEventRecord(stop_, 0);
    cudaEventSynchronize(stop_);
    cudaEventElapsedTime(&time_, start_, stop_);

    if (verbose) cout << "sg = " << sg << " non demand time = " << time_ << endl;

    CubDebugExit(cudaStreamSynchronize(streams[sg]));
    CubDebugExit(cudaStreamDestroy(streams[sg]));

    cuCtxPopCurrent(&poppedCtx);

  });

  CubDebugExit(cudaDeviceSynchronize());

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Probe time " << time << endl;
  cgp->execution_total += time;
  
  cudaEventRecord(start, 0);

  int* resGPU;
  if (custom) resGPU = (int*) cm->customCudaHostAlloc<int>(params->total_val * 6);
  else CubDebugExit(cudaHostAlloc((void**) &resGPU, params->total_val * 6 * sizeof(int), cudaHostAllocDefault));
  CubDebugExit(cudaMemcpy(resGPU, params->d_res, params->total_val * 6 * sizeof(int), cudaMemcpyDeviceToHost));
  cgp->gpu_to_cpu_total += (params->total_val * 6 * sizeof(int));

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  merge(params->res, resGPU, params->total_val);

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Merge time " << time << endl;
  cgp->merging_total += time;
}

void
QueryProcessing::runOnDemand() {
  int sg = 0;

  for (int i = 0; i < qo->join.size(); i++) {
    int table_id = qo->join[i].second->table_id;
    if (qo->segment_group_count[table_id][sg] > 0) {
      executeTableDimOD(table_id, sg);
    }
  }

  CubDebugExit(cudaDeviceSynchronize());

  if (qo->segment_group_count[0][sg] > 0) {
    executeTableFactOD(sg);
  }

  cm->resetOnDemand();

  CubDebugExit(cudaDeviceSynchronize());
};

void
QueryProcessing::runHybridOnDemand(int options) {

  assert(options == 1 || options == 2);

  cm->copySegmentList();

  for (int i = 0; i < qo->join.size(); i++) {
    int table_id = qo->join[i].second->table_id;

    parallel_for(short(0), qo->par_segment_count[table_id], [=](short j){

      int sg = qo->par_segment[table_id][j];

      CubDebugExit(cudaStreamCreate(&streams[sg]));

      if (qo->segment_group_count[table_id][sg] > 0) {
        executeTableDim(table_id, sg);
      }

      CubDebugExit(cudaStreamSynchronize(streams[sg]));
      CubDebugExit(cudaStreamDestroy(streams[sg]));

    });

    CubDebugExit(cudaDeviceSynchronize());
  }

  SETUP_TIMING();
  float time;
  cudaEventRecord(start, 0);

  parallel_for(short(0), qo->par_segment_count[0], [=](short i){

  // for (int i = 0; i < qo->par_segment_count[0]; i++) {
    int sg = qo->par_segment[0][i];

    // cout << sg << endl;

    CubDebugExit(cudaStreamCreate(&streams[sg]));

    if (qo->segment_group_count[0][sg] > 0) {
      if ((sg & 0x40) == 0x40) {
        // cout << "sg1 " << sg << endl;
        float time;
        SETUP_TIMING();
        cudaEventRecord(start, 0);

        executeTableFactOD2(sg);

        cudaEventRecord(stop, 0);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&time, start, stop);

        if (verbose) cout << "sg = " << sg << " on demand time = " << time << endl;
      } else {
        // cout << "sg2 " << sg << endl;
        float time;
        SETUP_TIMING();
        cudaEventRecord(start, 0);
        if (options == 1) {
          executeTableFact_v1(sg);
        } else if (options == 2) {
          executeTableFact_v2(sg);
        }
        cudaEventRecord(stop, 0);
        cudaEventSynchronize(stop);
        cudaEventElapsedTime(&time, start, stop);

        if (verbose) cout << "sg = " << sg << " non demand time = " << time << endl;
      }
    }

    CubDebugExit(cudaStreamSynchronize(streams[sg]));
    CubDebugExit(cudaStreamDestroy(streams[sg]));
  // }

  });

  cm->resetOnDemand();

  CubDebugExit(cudaDeviceSynchronize());

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Probe time " << time << endl;

  cudaEventRecord(start, 0);

  int* resGPU;
  if (custom) resGPU = (int*) cm->customCudaHostAlloc<int>(params->total_val * 6);
  else CubDebugExit(cudaHostAlloc((void**) &resGPU, params->total_val * 6 * sizeof(int), cudaHostAllocDefault));
  CubDebugExit(cudaMemcpy(resGPU, params->d_res, params->total_val * 6 * sizeof(int), cudaMemcpyDeviceToHost));
  cgp->gpu_to_cpu_total += (params->total_val * 6 * sizeof(int));
  merge(params->res, resGPU, params->total_val);

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Merge time " << time << endl;
};

void
QueryProcessing::runQueryHE(CUcontext ctx) {

  SETUP_TIMING();
  float time;
  cudaEventRecord(start, 0);

  for (int i = 0; i < qo->join.size(); i++) {
    int table_id = qo->join[i].second->table_id;

    // for (short j = 0; j < qo->par_segment_count[table_id]; j++) {

    parallel_for(int(0), qo->join[i].second->total_segment, [=](int j){

      CUcontext poppedCtx;
      cuCtxPushCurrent(ctx);

      // cuCtxSetCurrent(ctx);

      int sg = j;

      if (verbose) {
        cout << qo->join[i].second->column_name << endl;
        printf("sg = %d\n", sg);
      }

      CubDebugExit(cudaStreamCreate(&streams[sg]));

      if (qo->segment_group_count[table_id][sg] > 0) {
        executeTableDim_HE(table_id, sg);
      }

      CubDebugExit(cudaStreamSynchronize(streams[sg]));
      CubDebugExit(cudaStreamDestroy(streams[sg]));

      // cuCtxSetCurrent(NULL);

      cuCtxPopCurrent(&poppedCtx);
      // CHECK_CU_ERROR(cuCtxPopCurrent(&poppedCtx), "cuCtxPopCurrent");

    });

    // }

    CubDebugExit(cudaDeviceSynchronize());
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Build time " << time << endl;
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  parallel_for(int(0), cm->lo_orderdate->total_segment, [=](int i){

    CUcontext poppedCtx;
    cuCtxPushCurrent(ctx);

    int sg = i;

    CubDebugExit(cudaStreamCreate(&streams[sg]));

    float time_;
    cudaEvent_t start_, stop_; 
    cudaEventCreate(&start_); cudaEventCreate(&stop_);
    cudaEventRecord(start_, 0);

    if (qo->segment_group_count[0][sg] > 0) {
      executeTableFact_HE(sg);
    }

    cudaEventRecord(stop_, 0);
    cudaEventSynchronize(stop_);
    cudaEventElapsedTime(&time_, start_, stop_);

    if (verbose) cout << "sg = " << sg << " non demand time = " << time_ << endl;

    CubDebugExit(cudaStreamSynchronize(streams[sg]));
    CubDebugExit(cudaStreamDestroy(streams[sg]));

    cuCtxPopCurrent(&poppedCtx);

  });

  CubDebugExit(cudaDeviceSynchronize());

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Probe time " << time << endl;
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  int* resGPU;
  if (custom) resGPU = (int*) cm->customCudaHostAlloc<int>(params->total_val * 6);
  else CubDebugExit(cudaHostAlloc((void**) &resGPU, params->total_val * 6 * sizeof(int), cudaHostAllocDefault));
  CubDebugExit(cudaMemcpy(resGPU, params->d_res, params->total_val * 6 * sizeof(int), cudaMemcpyDeviceToHost));
  cgp->gpu_to_cpu_total += (params->total_val * 6 * sizeof(int));

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  cudaEventRecord(start, 0);

  merge(params->res, resGPU, params->total_val);

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  if (verbose) cout << "Merge time " << time << endl;
  cgp->merging_total += time;
}

void
QueryProcessing::profile() {
  for (int i = 0; i < NUM_QUERIES; i++) {

    // cudaEvent_t start, stop;
    SETUP_TIMING();

    float default_time = 0, time1 = 0, time2 = 0;

    query = queries[i];

    cout << endl;
    cout << endl;
    cout << endl;
    cout << "Query: " << query << endl;

    qo->parseQuery(query);

    for (int trials = 0; trials < 2; trials++) {

      qo->prepareQuery(query);
      qo->prepareOperatorPlacement();
      qo->groupBitmapSegmentTable(0, query, 1);
      for (int tbl = 0; tbl < qo->join.size(); tbl++) {
        qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query, 1);
      }
      params = qo->params;

      TIME_FUNC(runQuery(), default_time);

      cout << "Default time " << default_time << endl;

      qo->clearPlacement();
      endQuery();
    }

    cout << endl;

    qo->clearParsing();

    qo->parseQuery(query);

    for (int j = 0; j < qo->querySelectColumn.size(); j++) {
      cm->cacheColumnSegmentInGPU(qo->querySelectColumn[j], qo->querySelectColumn[j]->total_segment);

      for (int trials = 0; trials < 2; trials++) {
        qo->prepareQuery(query);
        qo->prepareOperatorPlacement();
        qo->groupBitmapSegmentTable(0, query, 1);
        for (int tbl = 0; tbl < qo->join.size(); tbl++) {
          qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query, 1);
        }
        params = qo->params;

        TIME_FUNC(runQuery2(), time1);

        qo->clearPlacement();
        endQuery();
      }

      cout << qo->querySelectColumn[j]->column_name << " " << time1 << endl;

      if (time1 < default_time) qo->speedup[query][qo->querySelectColumn[j]] = default_time - time1;
      else qo->speedup[query][qo->querySelectColumn[j]] = 0;

      cm->deleteColumnSegmentInGPU(qo->querySelectColumn[j], qo->querySelectColumn[j]->total_segment);
    }

    cout << endl;

    for (int j = 0; j < qo->join.size(); j++) {
      cm->cacheColumnSegmentInGPU(qo->join[j].first, qo->join[j].first->total_segment);
      cm->cacheColumnSegmentInGPU(qo->join[j].second, qo->join[j].second->total_segment);
      qo->prepareQuery(query);
      qo->prepareOperatorPlacement();
      qo->groupBitmapSegmentTable(0, query, 1);
      for (int tbl = 0; tbl < qo->join.size(); tbl++) {
        qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query, 1);
      }
      params = qo->params;

      TIME_FUNC(runQuery(), time1);

      TIME_FUNC(runQuery2(), time2);

      cout << time1 << " " << time2 << endl;

      if (time1 < time2) {
        cout << qo->join[j].first->column_name << " " << qo->join[j].second->column_name << " " << time1 << endl;
        if (time1 < default_time) {
          qo->speedup[query][qo->join[j].first] = default_time - time1;
          qo->speedup[query][qo->join[j].second] = default_time - time1;
        } else {
          qo->speedup[query][qo->join[j].first] = 0;
          qo->speedup[query][qo->join[j].second] = 0;
        }
      } else {
        cout << qo->join[j].first->column_name << " " << qo->join[j].second->column_name << " " << time2 << endl;
        if (time2 < default_time) {
          qo->speedup[query][qo->join[j].first] = default_time - time2;
          qo->speedup[query][qo->join[j].second] = default_time - time2;
        } else {
          qo->speedup[query][qo->join[j].first] = 0;
          qo->speedup[query][qo->join[j].second] = 0;
        }
      }

      cm->deleteColumnSegmentInGPU(qo->join[j].first, qo->join[j].first->total_segment);
      cm->deleteColumnSegmentInGPU(qo->join[j].second, qo->join[j].second->total_segment);

      qo->clearPlacement();
      endQuery();
    }

    cout << endl;

    for (int j = 0; j < qo->queryGroupByColumn.size(); j++) {
      cm->cacheColumnSegmentInGPU(qo->queryGroupByColumn[j], qo->queryGroupByColumn[j]->total_segment);
    }
    for (int j = 0; j < qo->queryAggrColumn.size(); j++) {
      cm->cacheColumnSegmentInGPU(qo->queryAggrColumn[j], qo->queryAggrColumn[j]->total_segment);
    }
    
    qo->prepareQuery(query);
    qo->prepareOperatorPlacement();
    qo->groupBitmapSegmentTable(0, query, 1);
      for (int tbl = 0; tbl < qo->join.size(); tbl++) {
        qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query, 1);
    }
    params = qo->params;

    TIME_FUNC(runQuery2(), time1);

    cout << "groupby aggregation " << time1 << endl;
    cout << endl;

    for (int j = 0; j < qo->queryGroupByColumn.size(); j++) {
      cm->deleteColumnSegmentInGPU(qo->queryGroupByColumn[j], qo->queryGroupByColumn[j]->total_segment);
      if (time1 < default_time) qo->speedup[query][qo->queryGroupByColumn[j]] = default_time - time1;
      else qo->speedup[query][qo->queryGroupByColumn[j]] = 0;
    }
    for (int j = 0; j < qo->queryAggrColumn.size(); j++) {
      cm->deleteColumnSegmentInGPU(qo->queryAggrColumn[j], qo->queryAggrColumn[j]->total_segment);
      if (time1 < default_time) qo->speedup[query][qo->queryAggrColumn[j]] = default_time - time1;
      else qo->speedup[query][qo->queryAggrColumn[j]] = 0;
    }

    qo->clearPlacement();
    endQuery();
    qo->clearParsing();

  }
}

double
QueryProcessing::processOnDemand() {
  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  qo->prepareOperatorPlacement();
  qo->groupBitmapSegmentTable(0, query);
    for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query);
  }
  params = qo->params;

  // cudaEvent_t start, stop;
  SETUP_TIMING();
  float time;

  TIME_FUNC(runOnDemand(), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
  //   cgp->cpu_time_total += cgp->cpu_time[sg];
  //   cgp->gpu_time_total += cgp->gpu_time[sg];
  //   cgp->transfer_time_total += cgp->transfer_time[sg];
  //   cgp->malloc_time_total += cgp->malloc_time[sg];
    cgp->cpu_time_total = max(cgp->cpu_time_total, cgp->cpu_time[sg]);
    cgp->gpu_time_total = max(cgp->gpu_time_total, cgp->gpu_time[sg]);
    cgp->transfer_time_total = max(cgp->transfer_time_total, cgp->transfer_time[sg]);
    cgp->malloc_time_total = max(cgp->malloc_time_total, cgp->malloc_time[sg]);

    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return time;
};


double
QueryProcessing::processHybridOnDemand(int options) {
  assert(options == 1 || options == 2);

  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  qo->prepareOperatorPlacement();
  qo->groupBitmapSegmentTableOD(0, query);
  for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTableOD(qo->join[tbl].second->table_id, query);
  }
  params = qo->params;

  // cudaEvent_t start, stop;
  SETUP_TIMING();
  float time;

  TIME_FUNC(runHybridOnDemand(options), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
    // cgp->cpu_time_total += cgp->cpu_time[sg];
    // cgp->gpu_time_total += cgp->gpu_time[sg];
    // cgp->transfer_time_total += cgp->transfer_time[sg];
    // cgp->malloc_time_total += cgp->malloc_time[sg];
    cgp->cpu_time_total = max(cgp->cpu_time_total, cgp->cpu_time[sg]);
    cgp->gpu_time_total = max(cgp->gpu_time_total, cgp->gpu_time[sg]);
    cgp->transfer_time_total = max(cgp->transfer_time_total, cgp->transfer_time[sg]);
    cgp->malloc_time_total = max(cgp->malloc_time_total, cgp->malloc_time[sg]);

    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return time;
};

double
QueryProcessing::processQuery(CUcontext ctx) {

  SETUP_TIMING();
  float time;

  cudaEventRecord(start, 0);

  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  params = qo->params;

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  if (verbose) {
    cout << "Query Prepare Time: " << time << endl;
    cout << endl;
  }

  cudaEventRecord(start, 0);

  qo->prepareOperatorPlacement();
  qo->groupBitmapSegmentTable(0, query);
    for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query);
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->optimization_total += time;

  if (verbose) {
    cout << "Query Optimization Time: " << time << endl;
    cout << endl;    
  }

  TIME_FUNC(runQuery(ctx), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
    // cgp->cpu_time_total += cgp->cpu_time[sg];
    // cgp->gpu_time_total += cgp->gpu_time[sg];
    // cgp->transfer_time_total += cgp->transfer_time[sg];
    // cgp->malloc_time_total += cgp->malloc_time[sg];
    cgp->cpu_time_total = max(cgp->cpu_time_total, cgp->cpu_time[sg]);
    cgp->gpu_time_total = max(cgp->gpu_time_total, cgp->gpu_time[sg]);
    cgp->transfer_time_total = max(cgp->transfer_time_total, cgp->transfer_time[sg]);
    cgp->malloc_time_total = max(cgp->malloc_time_total, cgp->malloc_time[sg]);

    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return cgp->execution_total + cgp->merging_total + cgp->optimization_total;

};

double
QueryProcessing::processQuery2(CUcontext ctx) {

  // cudaEvent_t start, stop;   // variables that holds 2 events 
  SETUP_TIMING();
  float time;

  cudaEventRecord(start, 0);

  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  params = qo->params;

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  if (verbose) {
    cout << "Query Prepare Time: " << time << endl;
    cout << endl;
  }

  cudaEventRecord(start, 0);

  qo->prepareOperatorPlacement();
  qo->groupBitmapSegmentTable(0, query);
    for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query);
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->optimization_total += time;

  if (verbose) {
    cout << "Query Optimization Time: " << time << endl;
    cout << endl;    
  }

  TIME_FUNC(runQuery2(ctx), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
    // cgp->cpu_time_total += cgp->cpu_time[sg];
    // cgp->gpu_time_total += cgp->gpu_time[sg];
    // cgp->transfer_time_total += cgp->transfer_time[sg];
    // cgp->malloc_time_total += cgp->malloc_time[sg];
    cgp->cpu_time_total = max(cgp->cpu_time_total, cgp->cpu_time[sg]);
    cgp->gpu_time_total = max(cgp->gpu_time_total, cgp->gpu_time[sg]);
    cgp->transfer_time_total = max(cgp->transfer_time_total, cgp->transfer_time[sg]);
    cgp->malloc_time_total = max(cgp->malloc_time_total, cgp->malloc_time[sg]);

    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  // updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return cgp->execution_total + cgp->merging_total + cgp->optimization_total;

};

double
QueryProcessing::processQueryNP(CUcontext ctx) {

  // cudaEvent_t start, stop;   // variables that holds 2 events 
  SETUP_TIMING();
  float time;

  cudaEventRecord(start, 0);

  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  params = qo->params;

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  if (verbose) {
    cout << "Query Prepare Time: " << time << endl;
    cout << endl;
  }

  cudaEventRecord(start, 0);

  qo->prepareOperatorPlacement();
  qo->groupBitmapSegmentTable(0, query);
    for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTable(qo->join[tbl].second->table_id, query);
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->optimization_total += time;

  if (verbose) {
    cout << "Query Optimization Time: " << time << endl;
    cout << endl;    
  }

  TIME_FUNC(runQueryNP(ctx), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
    // cgp->cpu_time_total += cgp->cpu_time[sg];
    // cgp->gpu_time_total += cgp->gpu_time[sg];
    // cgp->transfer_time_total += cgp->transfer_time[sg];
    // cgp->malloc_time_total += cgp->malloc_time[sg];
    cgp->cpu_time_total = max(cgp->cpu_time_total, cgp->cpu_time[sg]);
    cgp->gpu_time_total = max(cgp->gpu_time_total, cgp->gpu_time[sg]);
    cgp->transfer_time_total = max(cgp->transfer_time_total, cgp->transfer_time[sg]);
    cgp->malloc_time_total = max(cgp->malloc_time_total, cgp->malloc_time[sg]);

    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return cgp->execution_total + cgp->merging_total + cgp->optimization_total;

}



double
QueryProcessing::processQueryEMat(CUcontext ctx) {

  // cudaEvent_t start, stop;   // variables that holds 2 events 
  SETUP_TIMING();
  float time;

  cudaEventRecord(start, 0);

  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  params = qo->params;

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  if (verbose) {
    cout << "Query Prepare Time: " << time << endl;
    cout << endl;
  }

  cudaEventRecord(start, 0);

  qo->prepareOperatorPlacementEMat();
  qo->groupBitmapSegmentTableEMat(0, query);
    for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTableEMat(qo->join[tbl].second->table_id, query);
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->optimization_total += time;

  if (verbose) {
    cout << "Query Optimization Time: " << time << endl;
    cout << endl;    
  }

  TIME_FUNC(runQueryNP(ctx), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return cgp->execution_total + cgp->merging_total + cgp->optimization_total;

}

double
QueryProcessing::processQueryHE(CUcontext ctx) {

  SETUP_TIMING();
  float time;

  cudaEventRecord(start, 0);

  qo->parseQuery(query);
  qo->prepareQuery(query, dist);
  params = qo->params;

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->execution_total += time;

  if (verbose) {
    cout << "Query Prepare Time: " << time << endl;
    cout << endl;
  }

  cudaEventRecord(start, 0);

  qo->prepareOperatorPlacementHE();
  qo->groupBitmapSegmentTableHE(0, query);
    for (int tbl = 0; tbl < qo->join.size(); tbl++) {
      qo->groupBitmapSegmentTableHE(qo->join[tbl].second->table_id, query);
  }

  cudaEventRecord(stop, 0);
  cudaEventSynchronize(stop);
  cudaEventElapsedTime(&time, start, stop);
  cgp->optimization_total += time;

  if (verbose) {
    cout << "Query Optimization Time: " << time << endl;
    cout << endl;    
  }

  TIME_FUNC(runQueryHE(ctx), time);

  for (int sg = 0 ; sg < MAX_GROUPS; sg++) {
    cgp->cpu_time_total = max(cgp->cpu_time_total, cgp->cpu_time[sg]);
    cgp->gpu_time_total = max(cgp->gpu_time_total, cgp->gpu_time[sg]);
    cgp->transfer_time_total = max(cgp->transfer_time_total, cgp->transfer_time[sg]);
    cgp->malloc_time_total = max(cgp->malloc_time_total, cgp->malloc_time[sg]);

    cgp->cpu_to_gpu_total += cgp->cpu_to_gpu[sg];
    cgp->gpu_to_cpu_total += cgp->gpu_to_cpu[sg];
  }

  if (verbose) {
    cout << "Result:" << endl;
    int res_count = 0;
    for (int i=0; i< params->total_val; i++) {
      if (params->res[6*i+4] != 0) {
        cout << params->res[6*i] << " " << params->res[6*i+1] << " " << params->res[6*i+2] << " " << params->res[6*i+3] << " " << reinterpret_cast<unsigned long long*>(&params->res[6*i+4])[0]  << endl;
        res_count++;
      }
    }
    cout << "Res count = " << res_count << endl;
    cout << "Query Execution Time: " << time << endl;
    cout << "CPU Time: " << cgp->cpu_time_total << endl;
    cout << "GPU Time: " << cgp->gpu_time_total << endl;
    cout << "Transfer Time: " << cgp->transfer_time_total << endl;
    cout << "Malloc Time: " << cgp->malloc_time_total << endl;
    cout << endl;
  }

  updateStatsQuery();

  qo->clearPlacement();
  endQuery();
  qo->clearParsing();

  return cgp->execution_total + cgp->merging_total + cgp->optimization_total;

};


void
QueryProcessing::percentageData() {

  double fraction[NUM_QUERIES] = {0};

  cout << endl;
  for (int k = 0; k < NUM_QUERIES; k++) {
    int cur_query = queries[k];

    qo->parseQuery(cur_query);

    int total = 0;

    int cached = 0;

    for (int i = 0; i < qo->querySelectColumn.size(); i++) {
      ColumnInfo* column = qo->querySelectColumn[i];
      total += column->total_segment;
      cached += column->tot_seg_in_GPU;
    }

    for (int i = 0; i < qo->queryBuildColumn.size(); i++) {
      ColumnInfo* column = qo->queryBuildColumn[i];
      total += column->total_segment;
      cached += column->tot_seg_in_GPU;
    }

    for (int i = 0; i < qo->queryProbeColumn.size(); i++) {
      ColumnInfo* column = qo->queryProbeColumn[i];
      total += column->total_segment;
      cached += column->tot_seg_in_GPU;
    }

    for (int i = 0; i < qo->queryGroupByColumn.size(); i++) {
      ColumnInfo* column = qo->queryGroupByColumn[i];
      total += column->total_segment;
      cached += column->tot_seg_in_GPU;
    }

    for (int i = 0; i < qo->queryAggrColumn.size(); i++) {
      ColumnInfo* column = qo->queryAggrColumn[i];
      total += column->total_segment;
      cached += column->tot_seg_in_GPU;
    }

    fraction[k] = cached*1.0/total;

    cout << "Query " << cur_query << " fraction: " << fraction[k] << " total: " << total << " cached: " << cached << endl;

    qo->clearParsing();

  }
  cout << endl;


}

void
QueryProcessing::endQuery() {

  qo->clearPrepare();

  // qo->clearVector();

  cm->resetPointer();

  cgp->resetCGP();

  // cgp->resetTime();

}

void
QueryProcessing::updateStatsQuery() {
  chrono::high_resolution_clock::time_point cur_time = chrono::high_resolution_clock::now();
  chrono::duration<double> timestamp = cur_time - cgp->begin_time;
  // query_freq[query]++;

  // double time_count = timestamp.count();
  double time_count = logical_time;
  logical_time += 20;
  // logical_time += qo->queryJoinColumn.size();
  // logical_time += qo->queryAggrColumn.size();
  // logical_time += qo->queryGroupByColumn.size();

  for (int i = 0; i < qo->join.size(); i++) {
    for (int col = 0; col < qo->select_build[qo->join[i].second].size(); col++) {  
      cm->updateColumnTimestamp(qo->select_build[qo->join[i].second][col], time_count++);
      ColumnInfo* column = qo->select_build[qo->join[i].second][col];
      for (int seg_id = 0; seg_id < column->total_segment; seg_id++) {
        Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
        cm->updateSegmentTimeDirect(column, segment, time_count);
        cm->updateSegmentFreqDirect(column, segment);
      }
    }
    cm->updateColumnTimestamp(qo->join[i].second, time_count++);
    ColumnInfo* column = qo->join[i].second;
    for (int seg_id = 0; seg_id < column->total_segment; seg_id++) {
      Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
      cm->updateSegmentTimeDirect(column, segment, time_count);
      cm->updateSegmentFreqDirect(column, segment);
    }
  }

  parallel_for(short(0), qo->par_segment_count[0], [=](short i){

      double par_time_count = time_count;

      int sg = qo->par_segment[0][i];

      for (int col = 0; col < qo->selectCPUPipelineCol[sg].size(); col++) {
        ColumnInfo* column = qo->selectCPUPipelineCol[sg][col];
        cm->updateColumnTimestamp(column, par_time_count++);
        for (int seg = 0; seg < qo->segment_group_count[column->table_id][sg]; seg++) {
          int seg_id = qo->segment_group[column->table_id][sg * column->total_segment + seg];
          Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
          cm->updateSegmentTimeDirect(column, segment, par_time_count);
          cm->updateSegmentFreqDirect(column, segment);
        }
      }
      for (int col = 0; col < qo->selectGPUPipelineCol[sg].size(); col++) {
        ColumnInfo* column = qo->selectGPUPipelineCol[sg][col];
        cm->updateColumnTimestamp(column, par_time_count++);
        for (int seg = 0; seg < qo->segment_group_count[column->table_id][sg]; seg++) {
          int seg_id = qo->segment_group[column->table_id][sg * column->total_segment + seg];
          Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
          cm->updateSegmentTimeDirect(column, segment, par_time_count);
          cm->updateSegmentFreqDirect(column, segment);
        }
      }
      for (int col = 0; col < qo->joinGPUPipelineCol[sg].size(); col++) {
        ColumnInfo* column = qo->joinGPUPipelineCol[sg][col];
        cm->updateColumnTimestamp(column, par_time_count++);
        for (int seg = 0; seg < qo->segment_group_count[column->table_id][sg]; seg++) {
          int seg_id = qo->segment_group[column->table_id][sg * column->total_segment + seg];
          Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
          cm->updateSegmentTimeDirect(column, segment, par_time_count);
          cm->updateSegmentFreqDirect(column, segment);
        }
      }
      for (int col = 0; col < qo->joinCPUPipelineCol[sg].size(); col++) {
        ColumnInfo* column = qo->joinCPUPipelineCol[sg][col];
        cm->updateColumnTimestamp(column, par_time_count++);
        for (int seg = 0; seg < qo->segment_group_count[column->table_id][sg]; seg++) {
          int seg_id = qo->segment_group[column->table_id][sg * column->total_segment + seg];
          Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
          cm->updateSegmentTimeDirect(column, segment, par_time_count);
          cm->updateSegmentFreqDirect(column, segment);
        }
      }
      for (int col = 0; col < qo->queryGroupByColumn.size(); col++) {
        ColumnInfo* column = qo->queryGroupByColumn[col];
        cm->updateColumnTimestamp(column, par_time_count++);
        for (int seg = 0; seg < qo->segment_group_count[column->table_id][sg]; seg++) {
          int seg_id = qo->segment_group[column->table_id][sg * column->total_segment + seg];
          Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
          cm->updateSegmentTimeDirect(column, segment, par_time_count);
          cm->updateSegmentFreqDirect(column, segment);
        }
      }
      for (int col = 0; col < qo->queryAggrColumn.size(); col++) {
        ColumnInfo* column = qo->queryAggrColumn[col];
        cm->updateColumnTimestamp(column, par_time_count++);
        for (int seg = 0; seg < qo->segment_group_count[column->table_id][sg]; seg++) {
          int seg_id = qo->segment_group[column->table_id][sg * column->total_segment + seg];
          Segment* segment = qo->cm->index_to_segment[column->column_id][seg_id];
          cm->updateSegmentTimeDirect(column, segment, par_time_count);
          cm->updateSegmentFreqDirect(column, segment);
        }
      }

  });


  for (int i = 0; i < qo->querySelectColumn.size(); i++) {
    ColumnInfo* column = qo->querySelectColumn[i];
    cm->updateColumnFrequency(column);
    cm->updateColumnWeightDirect(column, qo->speedup[query][column]);
  }

  for (int i = 0; i < qo->queryBuildColumn.size(); i++) {
    ColumnInfo* column = qo->queryBuildColumn[i];
    cm->updateColumnFrequency(column);
    cm->updateColumnWeightDirect(column, qo->speedup[query][column]);
  }

  for (int i = 0; i < qo->queryProbeColumn.size(); i++) {
    ColumnInfo* column = qo->queryProbeColumn[i];
    cm->updateColumnFrequency(column);
    cm->updateColumnWeightDirect(column, qo->speedup[query][column]);
  }

  for (int i = 0; i < qo->queryGroupByColumn.size(); i++) {
    ColumnInfo* column = qo->queryGroupByColumn[i];
    cm->updateColumnFrequency(column); 
    cm->updateColumnWeightDirect(column, qo->speedup[query][column]);
  }

  for (int i = 0; i < qo->queryAggrColumn.size(); i++) {
    ColumnInfo* column = qo->queryAggrColumn[i];
    cm->updateColumnFrequency(column);
    cm->updateColumnWeightDirect(column, qo->speedup[query][column]);
  }
}

void
QueryProcessing::dumpTrace(string filename) {

    int data_size = 0;
    int cached_data = 0;

    for (int i = 1; i < cm->TOT_COLUMN; i++) {
      data_size += cm->allColumn[i]->total_segment;
      cached_data += cm->allColumn[i]->tot_seg_in_GPU;
    }

    FILE *fptr = fopen(filename.c_str(), "w");
    if (fptr == NULL)
    {
        printf("Could not open file\n");
        assert(0);
    }
   
    fprintf(fptr, "===========================\n");
    fprintf(fptr, "=======  CACHE INFO  ======\n");
    fprintf(fptr, "===========================\n");

    fprintf(fptr, "\n");
    fprintf(fptr, "Segment size: %d\n", SEGMENT_SIZE);
    fprintf(fptr, "Cache size: %d\n", cm->cache_total_seg);
    fprintf(fptr, "Data size: %d\n", data_size);
    fprintf(fptr, "Cached data: %d\n", cached_data);
    fprintf(fptr, "\n");

    for (int i = 1; i < cm->TOT_COLUMN; i++) {
        fprintf(fptr,"%s: %d/%d segments cached\n", cm->allColumn[i]->column_name.c_str(), cm->allColumn[i]->tot_seg_in_GPU, cm->allColumn[i]->total_segment);
    }

    fprintf(fptr, "\n");
    fprintf(fptr, "\n");
    fprintf(fptr, "\n");

    for (int i = 0; i < NUM_QUERIES; i++) {

        fprintf(fptr, "===========================\n");
        fprintf(fptr, "========  QUERY %d ========\n", queries[i]);
        fprintf(fptr, "===========================\n");

        qo->parseQuery(queries[i]);
        qo->prepareQuery(queries[i], dist);

        int* t_segment = new int[cm->TOT_COLUMN]();
        int* t_c_segment = new int[cm->TOT_COLUMN]();
        int total_cached = 0, total_touched = 0, total_cached_touched = 0;

        countTouchedSegment(0, t_segment, t_c_segment);
        for (int tbl = 0; tbl < qo->join.size(); tbl++) {
          countTouchedSegment(qo->join[tbl].second->table_id, t_segment, t_c_segment);
        }

        for (int col = 0; col < cm->TOT_COLUMN; col++)
        {
          total_cached+=cm->allColumn[col]->tot_seg_in_GPU;
          total_touched+=t_segment[col];
          total_cached_touched+=t_c_segment[col];
        }

        fprintf(fptr, "\n");
        fprintf(fptr,"Segment cached: %d\n", total_cached);
        fprintf(fptr,"Segment touched: %d\n", total_touched);
        fprintf(fptr,"Segment cached and touched: %d\n", total_cached_touched);
        fprintf(fptr, "\n");

        for (int col = 0; col < cm->TOT_COLUMN; col++)
        {
          if (t_segment[col] > 0) {
            fprintf(fptr, "\n");
            fprintf(fptr,"%s\n", cm->allColumn[col]->column_name.c_str());
            fprintf(fptr,"Speedup: %.3f\n", qo->speedup[queries[i]][cm->allColumn[col]]);
            fprintf(fptr,"Segment cached: %d\n", cm->allColumn[col]->tot_seg_in_GPU);
            fprintf(fptr,"Segment touched: %d\n", t_segment[col]);
            fprintf(fptr,"Segment cached and touched: %d\n", t_c_segment[col]);
            fprintf(fptr, "\n");
          }
        }

        fprintf(fptr, "\n");
        fprintf(fptr, "\n");
        fprintf(fptr, "\n");

        delete[] t_segment;
        delete[] t_c_segment;

        endQuery();
        qo->clearParsing();
    }

    fclose(fptr);
}


void
QueryProcessing::countTouchedSegment(int table_id, int* t_segment, int* t_c_segment) {
  int total_segment = cm->allColumn[cm->columns_in_table[table_id][0]]->total_segment;
  for (int i = 0; i < total_segment; i++) {
    if (qo->checkPredicate(table_id, i)) {
      for (int j = 0; j < qo->queryColumn[table_id].size(); j++) {
        ColumnInfo* column = qo->queryColumn[table_id][j];
        t_segment[column->column_id]++;
        if (cm->segment_bitmap[column->column_id][i]) t_c_segment[column->column_id]++;
      }
    }
  }
}