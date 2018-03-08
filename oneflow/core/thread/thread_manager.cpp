#include "oneflow/core/thread/thread_manager.h"
#include "oneflow/core/job/job_desc.h"
#include "oneflow/core/thread/cpu_thread.h"
#include "oneflow/core/thread/gpu_thread.h"

namespace oneflow {

ThreadMgr::~ThreadMgr() {
  for (size_t i = 0; i < threads_.size(); ++i) {
    ActorMsg msg = ActorMsg::BuildCommandMsg(-1, ActorCmd::kStopThread);
    threads_[i]->GetMsgChannelPtr()->Send(msg);
    delete threads_[i];
    LOG(INFO) << "actor thread " << i << " finish";
  }
}

Thread* ThreadMgr::GetThrd(int64_t thrd_id) { return threads_.at(thrd_id); }

ThreadMgr::ThreadMgr() {
  const JobDesc* job_desc = JobDesc::Singleton();
  int64_t thrd_id = 0;

#define ADD_CPU_THREAD(n) \
  FOR_RANGE(int64_t, i, 0, n) { threads_.push_back(new CpuThread(thrd_id++)); }

  ADD_CPU_THREAD(job_desc->CpuDeviceNum());
// gpu device
#ifdef WITH_CUDA
  FOR_RANGE(int64_t, i, 0, job_desc->GpuDeviceNum()) {
    threads_.push_back(new GpuThread(thrd_id++, i));
  }
#endif
  ADD_CPU_THREAD(job_desc->DecodeWorkerNum());
  ADD_CPU_THREAD(job_desc->BoxingWorkerNum());
  ADD_CPU_THREAD(1);  // CommNet Actor Thread
  ADD_CPU_THREAD(job_desc->PersistenceWorkerNum());
}

}  // namespace oneflow
