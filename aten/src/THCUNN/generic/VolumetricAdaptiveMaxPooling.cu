#ifndef THC_GENERIC_FILE
#define THC_GENERIC_FILE "generic/VolumetricAdaptiveMaxPooling.cu"
#else

#include <THCUNN/common.h>

// 5d tensor B x D x T x H x W

void THNN_(VolumetricAdaptiveMaxPooling_updateOutput)(
           THCState *state,
           THCTensor *input,
           THCTensor *output,
           THCIndexTensor *indices,
           int osizeT,
           int osizeW,
           int osizeH)
{
  THCUNN_assertSameGPU(state, 3, input, output, indices);

  THCUNN_argCheck(state, !input->is_empty() && (input->dim() == 4 || input->dim() == 5), 2, input,
                  "4D or 5D (batch mode) tensor expected for input, but got: %s");

  THCIndex_t *indices_data;
  scalar_t *output_data;
  scalar_t *input_data;

  int64_t sizeD, isizeT, isizeH, isizeW;
  int64_t istrideD, istrideT, istrideH, istrideW;
  int64_t totalZ;

  if (input->dim() == 4) {
    sizeD = input->size(0);
    isizeT = input->size(1);
    isizeH = input->size(2);
    isizeW = input->size(3);

    istrideD = input->stride(0);
    istrideT = input->stride(1);
    istrideH = input->stride(2);
    istrideW = input->stride(3);

    THCTensor_(resize4d)(state, output, sizeD, osizeT, osizeH, osizeW);
    THCIndexTensor_(resize4d)(state, indices, sizeD, osizeT, osizeH, osizeW);

    totalZ = sizeD * osizeT;
  } else {
    input = THCTensor_(newContiguous)(state, input);

    int64_t sizeB = input->size(0);
    sizeD = input->size(1);
    isizeT = input->size(2);
    isizeH = input->size(3);
    isizeW = input->size(4);

    istrideD = input->stride(1);
    istrideT = input->stride(2);
    istrideH = input->stride(3);
    istrideW = input->stride(4);

    THCTensor_(resize5d)(state, output, sizeB, sizeD, osizeT, osizeH, osizeW);
    THCIndexTensor_(resize5d)(state, indices, sizeB, sizeD, osizeT, osizeH, osizeW);

    totalZ = sizeB * sizeD * osizeT;
  }

  input_data = THCTensor_(data)(state, input);
  output_data = THCTensor_(data)(state, output);
  indices_data = THCIndexTensor_(data)(state, indices);

  int64_t offsetZ = 0;
  dim3 threads(32, 8);
  // each H*W plane is processed by blocksH thread blocks
  int blocksH = max((int)(16L / totalZ), 1);
  while (totalZ > 0) {
    dim3 blocks(totalZ > 65535 ? 65535 : totalZ, blocksH);
    cunn_VolumetricAdaptiveMaxPooling_updateOutput_kernel
      <<<blocks, threads, 0, THCState_getCurrentStream(state)>>>(
        input_data, output_data, indices_data, isizeT, isizeH, isizeW,
        osizeT, osizeH, osizeW, istrideD, istrideT, istrideH, istrideW, offsetZ
      );

    totalZ -= 65535;
    offsetZ += 65535;
    THCudaCheck(cudaGetLastError());
  }

  if (input->dim() == 5) {
    // clean
    THCTensor_(free)(state, input);
  }
}

void THNN_(VolumetricAdaptiveMaxPooling_updateGradInput)(
           THCState *state,
           THCTensor *input,
           THCTensor *gradOutput,
           THCTensor *gradInput,
           THCIndexTensor *indices)
{
  THCUNN_assertSameGPU(state, 4, input, indices, gradOutput, gradInput);

  gradOutput = THCTensor_(newContiguous)(state, gradOutput);

  THCTensor_(resizeAs)(state, gradInput, input);
  THCTensor_(zero)(state, gradInput);

  THCIndex_t *indices_data;
  scalar_t *gradInput_data;
  scalar_t *gradOutput_data;

  int64_t sizeD, isizeT, isizeH, isizeW;
  int64_t osizeT, osizeH, osizeW;
  int64_t totalZ;

  if (input->dim() == 4) {
    sizeD = input->size(0);
    isizeT = input->size(1);
    isizeH = input->size(2);
    isizeW = input->size(3);

    osizeT = gradOutput->size(1);
    osizeH = gradOutput->size(2);
    osizeW = gradOutput->size(3);
  } else {
    sizeD = input->size(1);
    isizeT = input->size(2);
    isizeH = input->size(3);
    isizeW = input->size(4);

    osizeT = gradOutput->size(2);
    osizeH = gradOutput->size(3);
    osizeW = gradOutput->size(4);
  }

  bool atomic = (isizeW%osizeW != 0) || (isizeH%osizeH != 0) || (isizeT%osizeT != 0);

  if (input->dim() == 4) {
    totalZ = sizeD * osizeT;
  } else {
    int sizeB = input->size(0);
    totalZ = sizeB * sizeD * osizeT;
  }

  indices_data = THCIndexTensor_(data)(state, indices);
  gradInput_data = THCTensor_(data)(state, gradInput);
  gradOutput_data = THCTensor_(data)(state, gradOutput);

  int64_t offsetZ = 0;
  dim3 threads(32, 8);
  // each H*W plane is processed by blocksH thread blocks
  int blocksH = max((int)(16L / totalZ), 1);
  while (totalZ > 0) {
    dim3 blocks(totalZ > 65535 ? 65535 : totalZ, blocksH);

    if (atomic)
    {
      cunn_atomic_VolumetricAdaptiveMaxPooling_updateGradInput_kernel
        <<<blocks, threads, 0, THCState_getCurrentStream(state)>>>(
          gradInput_data, gradOutput_data, indices_data,
          isizeT, isizeH, isizeW, osizeT, osizeH, osizeW, offsetZ
        );
    } else {
      cunn_VolumetricAdaptiveMaxPooling_updateGradInput_kernel
        <<<blocks, threads, 0, THCState_getCurrentStream(state)>>>(
          gradInput_data, gradOutput_data, indices_data,
          isizeT, isizeH, isizeW, osizeT, osizeH, osizeW, offsetZ
        );
    }

    totalZ -= 65535;
    offsetZ += 65535;
    THCudaCheck(cudaGetLastError());
  }
  // clean
  THCTensor_(free)(state, gradOutput);
}

#endif
