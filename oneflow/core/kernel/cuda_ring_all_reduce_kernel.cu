#include "oneflow/core/kernel/cuda_ring_all_reduce_kernel.h"
#include "oneflow/core/kernel/kernel_util.cuh"
#include <device_launch_parameters.h>
#include "oneflow/core/common/reduce_method.pb.h"

namespace oneflow {

namespace {

using Pack = ulong2;

constexpr int32_t PACK_SIZE = sizeof(Pack);
constexpr int32_t PACK_ALIGN = alignof(Pack);
constexpr int32_t NUM_WARP_PER_BLOCK = 8;
constexpr int32_t NUM_THREAD_PER_WARP = 32;
constexpr int32_t NUM_THREAD = NUM_THREAD_PER_WARP * NUM_WARP_PER_BLOCK;
constexpr int32_t NUM_PACK_PER_LINE_PER_THREAD = 8;
constexpr int32_t NUM_BLOCK_PER_LINK = 2;

__forceinline__ __device__ int64_t DivUp(int64_t n, int64_t val) { return (n + val - 1) / val; }

template<ReduceMethod method, typename T>
struct ReduceFunctor {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const;
};

template<typename T>
struct ReduceFunctor<ReduceMethod::kSum, T> {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const { return a + b; }
};

template<typename T>
struct ReduceFunctor<ReduceMethod::kProd, T> {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const { return a * b; }
};

template<typename T>
struct ReduceFunctor<ReduceMethod::kMax, T> {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const { return max(a, b); }
};

template<typename T>
struct ReduceFunctor<ReduceMethod::kMin, T> {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const { return min(a, b); }
};

template<ReduceMethod method, typename T, typename P>
struct PackReduceFunctor {
  static_assert(sizeof(P) % sizeof(T) == 0,
                "The size of the P must be a multiple of the size of T");
  union View {
    P p;
    T t[sizeof(P) / sizeof(T)];
  };
  __device__ __forceinline__ P operator()(const P& a, const P& b) const {
    View va;
    View vb;
    View vc;
    va.p = a;
    vb.p = b;
#pragma unroll
    for (size_t i = 0; i < sizeof(P) / sizeof(T); ++i) {
      vc.t[i] = ReduceFunctor<method, T>()(va.t[i], vb.t[i]);
    }
    return vc.p;
  }
};

template<ReduceMethod method, typename T>
struct PackReduceFunctor<method, T, T> {
  __device__ __forceinline__ T operator()(const T& a, const T& b) const {
    return ReduceFunctor<method, T>()(a, b);
  }
};

template<ReduceMethod method, typename T, typename P, int32_t BATCH>
struct BatchPackReduceFunctor {
  __device__ __forceinline__ void operator()(P (&res)[BATCH], const P (&a)[BATCH],
                                             const P (&b)[BATCH]) {
#pragma unroll
    for (int32_t i = 0; i < BATCH; ++i) { res[i] = PackReduceFunctor<method, T, P>()(a[i], b[i]); }
  }
};

template<typename T>
struct FetchFunctor {
  __device__ __forceinline__ void operator()(T& v, const T* p) { v = *p; }
};

template<typename T>
struct StoreFunctor {
  __device__ __forceinline__ void operator()(T* p, const T& v) { *p = v; }
};

template<>
struct FetchFunctor<Pack> {
  __device__ __forceinline__ void operator()(Pack& v, const Pack* p) {
    asm volatile("ld.volatile.global.v2.u64 {%0,%1}, [%2];"
                 : "=l"(v.x), "=l"(v.y)
                 : "l"(p)
                 : "memory");
  }
};

template<>
struct StoreFunctor<Pack> {
  __device__ __forceinline__ void operator()(Pack* p, const Pack& v) {
    asm volatile("st.volatile.global.v2.u64 [%0], {%1,%2};" ::"l"(p), "l"(v.x), "l"(v.y)
                 : "memory");
  }
};

template<typename T, int32_t BATCH, int32_t STRIDE, bool BOUND>
struct BatchFetchFunctor {
  __device__ __forceinline__ void operator()(T (&a)[BATCH], const T* start, const T* bound) {
#pragma unroll
    for (int32_t i = 0; i < BATCH; ++i) {
      const T* ptr = start + i * STRIDE;
      if (!BOUND || ptr < bound) { FetchFunctor<T>()(a[i], ptr); }
    }
  }
};

template<typename T, int32_t BATCH, int32_t STRIDE, bool BOUND>
struct BatchStoreFunctor {
  __device__ __forceinline__ void operator()(T* start, T (&a)[BATCH], const T* bound) {
#pragma unroll
    for (int32_t i = 0; i < BATCH; ++i) {
      T* ptr = start + i * STRIDE;
      if (!BOUND || ptr < bound) { StoreFunctor<T>()(ptr, a[i]); }
    }
  }
};

template<typename T, bool EN>
__device__ __forceinline__ T* PtrOffsetOrNull(T* ptr, const size_t offset) {
  if (EN) {
    return ptr + offset;
  } else {
    return nullptr;
  }
}

template<ReduceMethod method, typename T, typename P, int32_t BATCH, bool BOUND, bool RECV,
         bool SRC, bool SEND, bool DST>
__device__ __forceinline__ void BatchPackReduceOrCopy(const int64_t num_elem, const T* recv,
                                                      const T* src, T* send, T* dst) {
  constexpr int32_t NUM_PACK_PER_BATCH_PER_WARP = BATCH * NUM_THREAD_PER_WARP;
  constexpr int32_t NUM_ELEM_PER_PACK = sizeof(P) / sizeof(T);
  constexpr int32_t NUM_PACK_PER_BATCH_PER_BLOCK = NUM_PACK_PER_BATCH_PER_WARP * NUM_WARP_PER_BLOCK;
  const int32_t thread_id = threadIdx.x;
  const int32_t warp_id = thread_id / NUM_THREAD_PER_WARP;
  const int32_t lane_id = thread_id % NUM_THREAD_PER_WARP;
  const int32_t offset = warp_id * NUM_PACK_PER_BATCH_PER_WARP + lane_id;
  assert(num_elem % NUM_ELEM_PER_PACK == 0);
  const int64_t num_pack = num_elem / NUM_ELEM_PER_PACK;
  if (!BOUND) { assert(num_pack % NUM_PACK_PER_BATCH_PER_BLOCK == 0); }
  const int64_t num_batch = DivUp(num_pack, NUM_PACK_PER_BATCH_PER_BLOCK);
  const P* recv_bound = PtrOffsetOrNull<const P, RECV>(reinterpret_cast<const P*>(recv), num_pack);
  const P* src_bound = PtrOffsetOrNull<const P, SRC>(reinterpret_cast<const P*>(src), num_pack);
  const P* send_bound = PtrOffsetOrNull<P, SEND>(reinterpret_cast<P*>(send), num_pack);
  const P* dst_bound = PtrOffsetOrNull<P, DST>(reinterpret_cast<P*>(dst), num_pack);
  const P* recv_pack = PtrOffsetOrNull<const P, RECV>(reinterpret_cast<const P*>(recv), offset);
  const P* src_pack = PtrOffsetOrNull<const P, SRC>(reinterpret_cast<const P*>(src), offset);
  P* send_pack = PtrOffsetOrNull<P, SEND>(reinterpret_cast<P*>(send), offset);
  P* dst_pack = PtrOffsetOrNull<P, DST>(reinterpret_cast<P*>(dst), offset);
  P batch[BATCH];
  using PackBatchFetch = BatchFetchFunctor<P, BATCH, NUM_THREAD_PER_WARP, BOUND>;
  using PackBatchStore = BatchStoreFunctor<P, BATCH, NUM_THREAD_PER_WARP, BOUND>;
  using BatchPackReduce = BatchPackReduceFunctor<method, T, P, BATCH>;
  for (int64_t b = 0; b < num_batch; ++b) {
    if (RECV) { PackBatchFetch()(batch, recv_pack, recv_bound); }
    if (SRC) {
      if (!RECV) {
        PackBatchFetch()(batch, src_pack, src_bound);
      } else {
        P tmp[BATCH];
        PackBatchFetch()(tmp, src_pack, src_bound);
        BatchPackReduce()(batch, batch, tmp);
      }
    }
    if (SEND) { PackBatchStore()(send_pack, batch, send_bound); }
    if (DST) { PackBatchStore()(dst_pack, batch, dst_bound); }
    if (RECV) { recv_pack += NUM_PACK_PER_BATCH_PER_BLOCK; }
    if (SRC) { src_pack += NUM_PACK_PER_BATCH_PER_BLOCK; }
    if (SEND) { send_pack += NUM_PACK_PER_BATCH_PER_BLOCK; }
    if (DST) { dst_pack += NUM_PACK_PER_BATCH_PER_BLOCK; }
  }
}

template<ReduceMethod method, typename T, bool RECV, bool SRC, bool SEND, bool DST>
__device__ __forceinline__ void ReduceOrCopy(const int64_t num_elem, const T* recv, const T* src,
                                             T* send, T* dst) {
  BatchPackReduceOrCopy<method, T, Pack, NUM_PACK_PER_LINE_PER_THREAD, false, RECV, SRC, SEND, DST>(
      num_elem, recv, src, send, dst);
}

template<ReduceMethod method, typename T, bool RECV, bool SRC, bool SEND, bool DST>
__global__ void GenericOp(CudaRingAllReduceArg<T> arg) {
  const int32_t block_id = blockIdx.x;
  const int32_t link_id = block_id / NUM_BLOCK_PER_LINK;
  const int32_t block_id_in_link = block_id % NUM_BLOCK_PER_LINK;
  const int64_t num_elem_per_block = DivUp(arg.num_elem[link_id], NUM_BLOCK_PER_LINK);
  const int64_t block_offset = block_id_in_link * num_elem_per_block;
  const int64_t block_num_elem = min(num_elem_per_block, arg.num_elem[link_id] - block_offset);
  if (block_num_elem > 0) {
    ReduceOrCopy<method, T, RECV, SRC, SEND, DST>(
        block_num_elem, PtrOffsetOrNull<const T, RECV>(arg.recv[link_id], block_offset),
        PtrOffsetOrNull<const T, SRC>(arg.src[link_id], block_offset),
        PtrOffsetOrNull<T, SEND>(arg.send[link_id], block_offset),
        PtrOffsetOrNull<T, DST>(arg.dst[link_id], block_offset));
  }
}

template<ReduceMethod method, typename T, bool RECV, bool SRC, bool SEND, bool DST>
void LaunchGenericOp(DeviceCtx* ctx, const CudaRingAllReduceArg<T>& arg) {
  GenericOp<method, T, RECV, SRC, SEND, DST>
      <<<arg.num_links * NUM_BLOCK_PER_LINK, NUM_THREAD, 0, ctx->cuda_stream()>>>(arg);
}

}  // namespace

template<typename T>
void CudaRingAllReduceKernelUtil<T>::Send(DeviceCtx* ctx, CudaRingAllReduceArg<T> arg) {
  LaunchGenericOp<ReduceMethod::kSum, T, false, true, true, false>(ctx, arg);
}

template<typename T>
void CudaRingAllReduceKernelUtil<T>::RecvReduceSend(DeviceCtx* ctx, CudaRingAllReduceArg<T> arg) {
  LaunchGenericOp<ReduceMethod::kSum, T, true, true, true, false>(ctx, arg);
}

template<typename T>
void CudaRingAllReduceKernelUtil<T>::RecvReduceSendCopy(DeviceCtx* ctx,
                                                        CudaRingAllReduceArg<T> arg) {
  LaunchGenericOp<ReduceMethod::kSum, T, true, true, true, true>(ctx, arg);
}

template<typename T>
void CudaRingAllReduceKernelUtil<T>::RecvSendCopy(DeviceCtx* ctx, CudaRingAllReduceArg<T> arg) {
  LaunchGenericOp<ReduceMethod::kSum, T, true, false, true, true>(ctx, arg);
}

template<typename T>
void CudaRingAllReduceKernelUtil<T>::RecvCopy(DeviceCtx* ctx, CudaRingAllReduceArg<T> arg) {
  LaunchGenericOp<ReduceMethod::kSum, T, true, false, false, true>(ctx, arg);
}

#define INSTANTIATE_CUDA_RING_ALL_REDUCE_KERNEL_UTIL(type_cpp, type_proto) \
  template struct CudaRingAllReduceKernelUtil<type_cpp>;
OF_PP_FOR_EACH_TUPLE(INSTANTIATE_CUDA_RING_ALL_REDUCE_KERNEL_UTIL, FLOATING_DATA_TYPE_SEQ)

}  // namespace oneflow
