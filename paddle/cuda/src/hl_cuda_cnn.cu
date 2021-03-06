/* Copyright (c) 2016 PaddlePaddle Authors. All Rights Reserve.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <float.h>
#include "hl_base.h"
#include "hl_cnn.h"
#include "hl_device_functions.cuh"

__global__ void KeMaxPoolForward(const int nthreads,
                                 const real* inputData,
                                 const int channels,
                                 const int height,
                                 const int width,
                                 const int pooledH,
                                 const int pooledW,
                                 const int ksizeW,
                                 const int ksizeH,
                                 const int strideH,
                                 const int strideW,
                                 const int offsetH,
                                 const int offsetW,
                                 real* tgtData,
                                 const int tgtStride) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < nthreads) {
    int pw = index % pooledW;
    int ph = (index / pooledW) % pooledH;
    int c = (index / pooledW / pooledH) % channels;
    int frameNum = index / pooledW / pooledH / channels;
    int hstart = ph * strideH - offsetH;
    int wstart = pw * strideW - offsetW;
    int hend = min(hstart + ksizeH, height);
    int wend = min(wstart + ksizeW, width);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    real maxval = -FLT_MAX;
    inputData += (frameNum * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        if (maxval < inputData[h * width + w])
          maxval = inputData[h * width + w];
      }
    }
    int tgtIndex =
        index % (pooledW * pooledH * channels) + frameNum * tgtStride;
    tgtData[tgtIndex] = maxval;
  }
}

void hl_maxpool_forward(const int frameCnt,
                        const real* inputData,
                        const int channels,
                        const int height,
                        const int width,
                        const int pooledH,
                        const int pooledW,
                        const int sizeX,
                        const int sizeY,
                        const int strideH,
                        const int strideW,
                        const int paddingH,
                        const int paddingW,
                        real* tgtData,
                        const int tgtStride) {
  int num_kernels = pooledH * pooledW * channels * frameCnt;
  int blocks = (num_kernels + 1024 - 1) / 1024;
  dim3 threads(1024, 1);
  dim3 grid(blocks, 1);

  KeMaxPoolForward<<<grid, threads, 0, STREAM_DEFAULT>>>(num_kernels,
                                                         inputData,
                                                         channels,
                                                         height,
                                                         width,
                                                         pooledH,
                                                         pooledW,
                                                         sizeX,
                                                         sizeY,
                                                         strideH,
                                                         strideW,
                                                         paddingH,
                                                         paddingW,
                                                         tgtData,
                                                         tgtStride);
  CHECK_SYNC("hl_maxpool_forward failed");
}

__global__ void KeMaxPoolBackward(const int nthreads,
                                  const real* inputData,
                                  const real* outData,
                                  const real* outGrad,
                                  const int channels,
                                  const int height,
                                  const int width,
                                  const int pooledH,
                                  const int pooledW,
                                  const int sizeX,
                                  const int sizeY,
                                  const int strideH,
                                  const int strideW,
                                  const int padH,
                                  const int padW,
                                  real scaleA,
                                  real scaleB,
                                  real* targetGrad,
                                  const int outStride) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < nthreads) {
    // find out the local index
    // find out the local offset
    int offsetW = index % width + padW;
    int offsetH = (index / width) % height + padH;
    int offsetC = (index / width / height) % channels;

    int frameNum = index / width / height / channels;
    int phstart = (offsetH < sizeY) ? 0 : (offsetH - sizeY) / strideH + 1;
    int pwstart = (offsetW < sizeX) ? 0 : (offsetW - sizeX) / strideW + 1;
    int phend = offsetH >= 0 ? min(offsetH / strideH + 1, pooledH) : 0;
    int pwend = offsetW >= 0 ? min(offsetW / strideW + 1, pooledW) : 0;
    real gradient = 0;
    real input = inputData[index];
    outData += (frameNum * outStride + offsetC * pooledH * pooledW);
    outGrad += (frameNum * outStride + offsetC * pooledH * pooledW);
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        if (input == outData[ph * pooledW + pw]) {
          gradient += outGrad[ph * pooledW + pw];
        }
      }
    }
    targetGrad[index] = scaleB * targetGrad[index] + scaleA * gradient;
  }
}

void hl_maxpool_backward(const int frameCnt,
                         const real* inputData,
                         const real* outData,
                         const real* outGrad,
                         const int channels,
                         const int height,
                         const int width,
                         const int pooledH,
                         const int pooledW,
                         const int sizeX,
                         const int sizeY,
                         const int strideH,
                         const int strideW,
                         const int paddingH,
                         const int paddingW,
                         real scaleA,
                         real scaleB,
                         real* targetGrad,
                         const int outStride) {
  int num_kernels = height * width * channels * frameCnt;
  int blocks = (num_kernels + 1024 - 1) / 1024;

  KeMaxPoolBackward<<<blocks, 1024, 0, STREAM_DEFAULT>>>(num_kernels,
                                                         inputData,
                                                         outData,
                                                         outGrad,
                                                         channels,
                                                         height,
                                                         width,
                                                         pooledH,
                                                         pooledW,
                                                         sizeX,
                                                         sizeY,
                                                         strideH,
                                                         strideW,
                                                         paddingH,
                                                         paddingW,
                                                         scaleA,
                                                         scaleB,
                                                         targetGrad,
                                                         outStride);
  CHECK_SYNC("hl_maxpool_backward");
}

__global__ void KeAvgPoolForward(const int nthreads,
                                 const real* inputData,
                                 const int channels,
                                 const int height,
                                 const int width,
                                 const int pooledH,
                                 const int pooledW,
                                 const int sizeX,
                                 const int sizeY,
                                 const int strideH,
                                 const int strideW,
                                 const int padH,
                                 const int padW,
                                 real* tgtData,
                                 const int tgtStride) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < nthreads) {
    int pw = index % pooledW;
    int ph = (index / pooledW) % pooledH;
    int c = (index / pooledW / pooledH) % channels;
    int frameNum = index / pooledW / pooledH / channels;

    int hstart = ph * strideH - padH;
    int wstart = pw * strideW - padW;
    int hend = min(hstart + sizeY, height + padH);
    int wend = min(wstart + sizeX, width + padW);
    int pool_size = (hend - hstart) * (wend - wstart);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    hend = min(hend, height);
    wend = min(wend, width);

    real aveval = 0;
    inputData += (frameNum * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        aveval += inputData[h * width + w];
      }
    }
    int tgtIndex =
        index % (pooledW * pooledH * channels) + frameNum * tgtStride;
    tgtData[tgtIndex] = aveval / pool_size;
  }
}

void hl_avgpool_forward(const int frameCnt,
                        const real* inputData,
                        const int channels,
                        const int height,
                        const int width,
                        const int pooledH,
                        const int pooledW,
                        const int sizeX,
                        const int sizeY,
                        const int strideH,
                        const int strideW,
                        const int paddingH,
                        const int paddingW,
                        real* tgtData,
                        const int tgtStride) {
  int num_kernels = pooledH * pooledW * channels * frameCnt;
  int blocks = (num_kernels + 1024 - 1) / 1024;
  KeAvgPoolForward<<<blocks, 1024, 0, STREAM_DEFAULT>>>(num_kernels,
                                                        inputData,
                                                        channels,
                                                        height,
                                                        width,
                                                        pooledH,
                                                        pooledW,
                                                        sizeX,
                                                        sizeY,
                                                        strideH,
                                                        strideW,
                                                        paddingH,
                                                        paddingW,
                                                        tgtData,
                                                        tgtStride);
  CHECK_SYNC("hl_avgpool_forward failed");
}

__global__ void KeAvgPoolBackward(const int nthreads,
                                  const real* outGrad,
                                  const int channels,
                                  const int height,
                                  const int width,
                                  const int pooledH,
                                  const int pooledW,
                                  const int sizeX,
                                  const int sizeY,
                                  const int strideH,
                                  const int strideW,
                                  const int padH,
                                  const int padW,
                                  real scaleA,
                                  real scaleB,
                                  real* tgtGrad,
                                  const int outStride) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < nthreads) {
    int offsetW = index % width + padW;
    int offsetH = (index / width) % height + padH;
    int offsetC = (index / width / height) % channels;
    int frameNum = index / width / height / channels;

    int phstart = (offsetH < sizeY) ? 0 : (offsetH - sizeY) / strideH + 1;
    int pwstart = (offsetW < sizeX) ? 0 : (offsetW - sizeX) / strideW + 1;
    int phend = offsetH >= 0 ? min(offsetH / strideH + 1, pooledH) : 0;
    int pwend = offsetW >= 0 ? min(offsetW / strideW + 1, pooledW) : 0;
    real gradient = 0;
    outGrad += (frameNum * outStride + offsetC * pooledH * pooledW);

    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        // figure out the pooling size
        int hstart = ph * strideH - padH;
        int wstart = pw * strideW - padW;
        int hend = min(hstart + sizeY, height + padH);
        int wend = min(wstart + sizeX, width + padW);
        int poolsize = (hend - hstart) * (wend - wstart);
        gradient += outGrad[ph * pooledW + pw] / poolsize;
      }
    }
    tgtGrad[index] = scaleB * tgtGrad[index] + scaleA * gradient;
  }
}

void hl_avgpool_backward(const int frameCnt,
                         const real* outGrad,
                         const int channels,
                         const int height,
                         const int width,
                         const int pooledH,
                         const int pooledW,
                         const int sizeX,
                         const int sizeY,
                         const int strideH,
                         const int strideW,
                         const int paddingH,
                         const int paddingW,
                         real scaleA,
                         real scaleB,
                         real* backGrad,
                         const int outStride) {
  int num_kernels = height * width * channels * frameCnt;
  int blocks = (num_kernels + 1024 - 1) / 1024;

  KeAvgPoolBackward<<<blocks, 1024, 0, STREAM_DEFAULT>>>(num_kernels,
                                                         outGrad,
                                                         channels,
                                                         height,
                                                         width,
                                                         pooledH,
                                                         pooledW,
                                                         sizeX,
                                                         sizeY,
                                                         strideH,
                                                         strideW,
                                                         paddingH,
                                                         paddingW,
                                                         scaleA,
                                                         scaleB,
                                                         backGrad,
                                                         outStride);
  CHECK_SYNC("hl_avgpool_backward failed");
}

__global__ void KeBilinearInterpFw(const real* in,
                                   const size_t inImgH,
                                   const size_t inImgW,
                                   const size_t inputH,
                                   const size_t inputW,
                                   real* out,
                                   const size_t outImgH,
                                   const size_t outImgW,
                                   const size_t outputH,
                                   const size_t outputW,
                                   const size_t numChannels,
                                   const real ratioH,
                                   const real ratioW) {
  int nthreads = outputH * outputW;
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid < nthreads) {
    int outIdH = tid / outputW;
    int outIdW = tid % outputW;
    int inImgSize = inputW / numChannels;
    int outImgSize = outputW / numChannels;
    int channelId = outIdW / outImgSize;

    int outImgIdy = (outIdW % outImgSize) / outImgW;
    int inImgIdy = ratioH * outImgIdy;
    int hId = (inImgIdy < inImgH - 1) ? 1 : 0;
    real h1lambda = ratioH * outImgIdy - inImgIdy;
    real h2lambda = 1.f - h1lambda;

    int outImgIdx = tid % outImgW;
    int inImgIdx = ratioW * outImgIdx;
    int wId = (inImgIdx < inImgW - 1) ? 1 : 0;
    real w1lambda = ratioW * outImgIdx - inImgIdx;
    real w2lambda = 1.f - w1lambda;

    const real* inPos = &in[outIdH * inputW + channelId * inImgSize +
                            inImgIdy * inImgW + inImgIdx];

    // bilinear interpolation
    out[outIdH * outputW + outIdW] =
        h2lambda * (w2lambda * inPos[0] + w1lambda * inPos[wId]) +
        h1lambda * (w2lambda * inPos[hId * inImgW] +
                    w1lambda * inPos[hId * inImgW + wId]);
  }
}

void hl_bilinear_forward(const real* inData,
                         const size_t inImgH,
                         const size_t inImgW,
                         const size_t inputH,
                         const size_t inputW,
                         real* outData,
                         const size_t outImgH,
                         const size_t outImgW,
                         const size_t outputH,
                         const size_t outputW,
                         const size_t numChannels,
                         const real ratioH,
                         const real ratioW) {
  int threadNum = outputH * outputW;
  int blocks = (threadNum + 1024 - 1) / 1024;

  KeBilinearInterpFw<<<blocks, 1024, 0, STREAM_DEFAULT>>>(inData,
                                                          inImgH,
                                                          inImgW,
                                                          inputH,
                                                          inputW,
                                                          outData,
                                                          outImgH,
                                                          outImgW,
                                                          outputH,
                                                          outputW,
                                                          numChannels,
                                                          ratioH,
                                                          ratioW);
  CHECK_SYNC("hl_bilinear_forward failed");
}

__global__ void KeBilinearInterpBw(real* in,
                                   const size_t inImgH,
                                   const size_t inImgW,
                                   const size_t inputH,
                                   const size_t inputW,
                                   const real* out,
                                   const size_t outImgH,
                                   const size_t outImgW,
                                   const size_t outputH,
                                   const size_t outputW,
                                   const size_t numChannels,
                                   const real ratioH,
                                   const real ratioW) {
  int nthreads = outputH * outputW;
  int tid = blockIdx.x * blockDim.x + threadIdx.x;
  if (tid < nthreads) {
    int outIdH = tid / outputW;
    int outIdW = tid % outputW;
    int inImgSize = inputW / numChannels;
    int outImgSize = outputW / numChannels;
    int channelId = outIdW / outImgSize;

    int outImgIdy = (outIdW % outImgSize) / outImgW;
    int inImgIdy = ratioH * outImgIdy;
    int hId = (inImgIdy < inImgH - 1) ? 1 : 0;
    real h1lambda = ratioH * outImgIdy - inImgIdy;
    real h2lambda = 1.f - h1lambda;

    int outImgIdx = tid % outImgW;
    int inImgIdx = ratioW * outImgIdx;
    int wId = (inImgIdx < inImgW - 1) ? 1 : 0;
    real w1lambda = ratioW * outImgIdx - inImgIdx;
    real w2lambda = 1.f - w1lambda;

    real* inPos = &in[outIdH * inputW + channelId * inImgSize +
                      inImgIdy * inImgW + inImgIdx];
    const real* outPos = &out[outIdH * outputW + outIdW];
    paddle::paddleAtomicAdd(&inPos[0], h2lambda * w2lambda * outPos[0]);
    paddle::paddleAtomicAdd(&inPos[wId], h2lambda * w1lambda * outPos[0]);
    paddle::paddleAtomicAdd(&inPos[hId * inImgW],
                            h1lambda * w2lambda * outPos[0]);
    paddle::paddleAtomicAdd(&inPos[hId * inImgW + wId],
                            h1lambda * w1lambda * outPos[0]);
  }
}

void hl_bilinear_backward(real* inGrad,
                          const size_t inImgH,
                          const size_t inImgW,
                          const size_t inputH,
                          const size_t inputW,
                          const real* outGrad,
                          const size_t outImgH,
                          const size_t outImgW,
                          const size_t outputH,
                          const size_t outputW,
                          const size_t numChannels,
                          const real ratioH,
                          const real ratioW) {
  int threadNum = outputH * outputW;
  int blocks = (threadNum + 1024 - 1) / 1024;

  KeBilinearInterpBw<<<blocks, 1024, 0, STREAM_DEFAULT>>>(inGrad,
                                                          inImgH,
                                                          inImgW,
                                                          inputH,
                                                          inputW,
                                                          outGrad,
                                                          outImgH,
                                                          outImgW,
                                                          outputH,
                                                          outputW,
                                                          numChannels,
                                                          ratioH,
                                                          ratioW);
  CHECK_SYNC("hl_bilinear_backward failed");
}

__global__ void maxoutFpCompute(size_t nthreads,
                                const real* inData,
                                real* outData,
                                int* idData,
                                size_t size,
                                size_t featLen,
                                size_t groups) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < nthreads) {
    size_t batch_idx = index / size;
    size_t i = index % size;
    size_t channel_idx = i / featLen;
    size_t feat_idx = i % featLen;
    size_t data_idx =
        (batch_idx * size + channel_idx * featLen) * groups + feat_idx;
    real max = inData[data_idx];
    int maxId = 0;
    for (size_t g = 1; g < groups; ++g) {
      real tmp = inData[data_idx + g * featLen];
      if (tmp > max) {
        max = tmp;
        maxId = g;
      }
    }
    outData[index] = max;
    idData[index] = maxId;
  }
}

void hl_maxout_forward(const real* inData,
                       real* outData,
                       int* idData,
                       size_t batchSize,
                       size_t size,
                       size_t featLen,
                       size_t groups) {
  int num_kernels = size * batchSize;
  int blocks = (num_kernels + 1024 - 1) / 1024;
  maxoutFpCompute<<<blocks, 1024, 0, STREAM_DEFAULT>>>(
      num_kernels, inData, outData, idData, size, featLen, groups);
  CHECK_SYNC("hl_maxout_forward failed");
}

__global__ void maxoutBpCompute(size_t nthreads,
                                real* inGrad,
                                const real* outGrad,
                                const int* idData,
                                size_t size,
                                size_t featLen,
                                size_t groups) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < nthreads) {
    size_t batch_idx = index / size;
    size_t i = index % size;
    size_t channel_idx = i / featLen;
    size_t feat_idx = i % featLen;
    size_t newIndex = batch_idx * size;
    size_t gradIdx =
        (channel_idx * groups + (idData + newIndex)[i]) * featLen + feat_idx;
    (inGrad + newIndex * groups)[gradIdx] += (outGrad + newIndex)[i];
  }
}

void hl_maxout_backward(real* inGrad,
                        const real* outGrad,
                        const int* idData,
                        size_t batchSize,
                        size_t size,
                        size_t featLen,
                        size_t groups) {
  int num_kernels = size * batchSize;
  int blocks = (num_kernels + 1024 - 1) / 1024;
  maxoutBpCompute<<<blocks, 1024, 0, STREAM_DEFAULT>>>(
      num_kernels, inGrad, outGrad, idData, size, featLen, groups);
  CHECK_SYNC("hl_maxout_backward failed");
}
