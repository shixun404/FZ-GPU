#include <cuda_runtime.h>
#include <dirent.h>
#include <stdint.h>
#include <sys/stat.h>
#include <thrust/copy.h>
#include <chrono>
#include <cub/cub.cuh>
#include <fstream>
#include <iostream>
#include <algorithm>

// #include "include/kernel/cpplaunch_cuda.hh"
#include "include/kernel/lorenzo_var.cuh"
#include "include/utils/cuda_err.cuh"
#include "include/utils/io.hh"

#define UINT32_BIT_LEN 32

// struct is_true
// {
//   __host__ __device__
//   bool operator()(const unsigned char x)
//   {
//     return x == 1;
//   }
// };

long GetFileSize(std::string filename)
{
    struct stat stat_buf;
    int         rc = stat(filename.c_str(), &stat_buf);
    return rc == 0 ? stat_buf.st_size : -1;
}

template <typename T>
T* read_binary_to_new_array(const std::string& fname, size_t dtype_len)
{
    std::ifstream ifs(fname.c_str(), std::ios::binary | std::ios::in);
    if (not ifs.is_open()) {
        std::cerr << "fail to open " << fname << std::endl;
        exit(1);
    }
    auto _a = new T[dtype_len]();
    ifs.read(reinterpret_cast<char*>(_a), std::streamsize(dtype_len * sizeof(T)));
    ifs.close();
    return _a;
}

template <typename T>
void write_array_to_binary(const std::string& fname, T* const _a, size_t const dtype_len)
{
    std::ofstream ofs(fname.c_str(), std::ios::binary | std::ios::out);
    if (not ofs.is_open()) return;
    ofs.write(reinterpret_cast<const char*>(_a), std::streamsize(dtype_len * sizeof(T)));
    ofs.close();
}

// __global__ void generateBitFlagArray(int blockSize, uint8_t* d_in, uint32_t* d_bitFlagArray, uint8_t*
// d_byteFlagArray) {
//     // __shared__ unsigned char[thread.dim * blockSize] originalData;
//     int tid = threadIdx.x + blockIdx.x * blockDim.x;
//     uint8_t sum = 0;

//     for(int i = 0; i < blockSize; i++) {
//         sum |= d_in[tid * blockSize + i];
//         // originalData[thread.x * blockSize + i] = d_in[tid * blockSize + i];
//     }
//     for(int i = 0; i < blockSize; i++) {
//         d_byteFlagArray[tid * blockSize + i] = (sum!=0);
//         // originalData[thread.x * blockSize + i] = d_in[tid * blockSize + i];
//     }
//     d_bitFlagArray[blockIdx.x] = __ballot_sync(0xFFFFFFFFU, sum != 0);
// }

// processing 16 bytes * 32 threads = 512 bytes -> 4 * 128 bytes
__global__ void
generateBitFlagArrayDebug(int blockSize, uint8_t* _d_in, uint32_t* d_bitFlagArray, uint8_t* d_byteFlagArray)
{
    // __shared__ unsigned char[thread.dim * blockSize] originalData;
    __shared__ struct {
        uint32_t databuffer[128];
        // uint32_t bigflatarray[];
    } shm;

    static const int WARPSIZE = 32;
    // at the same time, WARPSIZE = blockDim.x

    auto d_in = reinterpret_cast<uint32_t*>(_d_in);

    const auto gidx_base = 128 * blockIdx.x;

    for (auto i = 0; i < 4; i++) {
        auto local_idx            = threadIdx.x + WARPSIZE * i;
        shm.databuffer[local_idx] = d_in[gidx_base + local_idx];
    }
    __syncthreads();

    uint32_t sum = 0;
    for (auto i = 0; i < 4; i++) { sum |= shm.databuffer[i + threadIdx.x * 4]; }

    int tid = threadIdx.x + blockIdx.x * blockDim.x;
    // uint8_t sum = 0;

    // for(int i = 0; i < blockSize; i++) {
    //     sum |= d_in[tid * blockSize + i];
    // }
    d_byteFlagArray[tid] = (sum != 0);
    auto ballot_res      = __ballot_sync(0xFFFFFFFFU, sum != 0);
    if (threadIdx.x == 0) d_bitFlagArray[blockIdx.x] = ballot_res;
}

__global__ void encodeDebug(int blockSize, uint8_t* d_in, uint8_t* d_out, uint32_t* preSum)
{
    __shared__ uint32_t sumArr[33];
    int                 tid = threadIdx.x + blockIdx.x * blockDim.x;
    sumArr[0]               = preSum[tid];
    sumArr[threadIdx.x + 1] = preSum[tid + 1];
    __syncthreads();
    if (sumArr[threadIdx.x + 1] != sumArr[threadIdx.x]) {
        for (int i = 0; i < blockSize; i++) { d_out[sumArr[threadIdx.x] * blockSize + i] = d_in[tid * blockSize + i]; }
    }
}

// __global__ void bitShuffle(uint16_t* in){
//     // __shared__ unsigned char s_in[32];
//     // __shared__ uint32_t bitFlagArray[16];
//     extern __shared__ uint32_t s[];
//     uint32_t *bitFlagArray = s;
//     uint16_t *bitFlagArrayUint16 = (uint16_t*)s;

//     // s_in[threadIdx.x] = in[threadIdx.x + blockIdx.x * 32];
//     // __syncthreads();

//     uint16_t buffer = in[threadIdx.x + blockIdx.x * blockDim.x];
//     #pragma unroll 16
//     for( int i = 0; i < 16; i++ ) {
//         bitFlagArray[i] = __ballot_sync(0xFFFFFFFFU,  buffer & (1U<<i) );
//     }
//     // __syncthreads();
//     in[threadIdx.x + blockIdx.x * blockDim.x] = bitFlagArrayUint16[threadIdx.x];
//     // out[threadIdx.x + blockIdx.x * 32] = (bitFlagArray[int(threadIdx.x / 4)] >> (8 * threadIdx.x % 4)) & 0xff;
// }

__global__ void bitshuffleDebug(const uint32_t* __restrict__ in, uint32_t* __restrict__ out)
{
    /*
    grid 32x32 threads
    each thread loads 4 bytes (aligned) = 128 bytes per row of 32
    total bytes loaded = 32x32x4 = 4096 bytes
                  x                y  z
    blocks = ( total_bytes / 8192, 2, 1 )
    */
    __shared__ uint32_t smem[32][33];
    uint32_t            v;
    /* This thread is going to load 4 bytes. Next thread in x will load
    the next 4 to be aligned. In total we pick up 32*4 = 128 bytes in this
    row of 32 (warp) for bit0.
    The next row (warp) is going to pick up bit1, etc
    The first grid starts at byte 0 + blockIdx.x * 2048
    The second grid starts at byte 8192/32/2
     */
    smem[threadIdx.y][threadIdx.x] =
        in[threadIdx.x +        // Aligned loads. 32*4 = 128 bytes
           threadIdx.y * 32 +   // Offset to next bit = 8192/32/4.
           blockIdx.x * 2048 +  // Start of the block
           blockIdx.y * 1024];  // Next 32 reads
    __syncthreads();            /* Now we loaded 4 kB to smem.   Do the first level of transpose */
    v = smem[threadIdx.y][threadIdx.x];
#pragma unroll 32
    for (int i = 0; i < 32; i++) smem[threadIdx.y][i] = __ballot_sync(0xFFFFFFFFU, v & (1U << i));
    __syncthreads(); /* Now we loaded 4 kB to smem.   Do the first level of transpose */
    out[threadIdx.x + threadIdx.y * 32 + blockIdx.y * 1024 + blockIdx.x * 2048] = smem[threadIdx.x][threadIdx.y];
}

__global__ void bitshuffleAndBitflag(
    const uint32_t* __restrict__ in,
    uint32_t* __restrict__ out,
    int       blockSize,
    uint32_t* d_bitFlagArray,
    uint32_t*  d_byteFlagArray)
{
    /*
    grid 32x32 threads
    each thread loads 4 bytes (aligned) = 128 bytes per row of 32
    total bytes loaded = 32x32x4 = 4096 bytes
                  x                y  z
    blocks = ( total_bytes / 8192, 2, 1 )
    */
    __shared__ uint32_t smem[32][33];
    uint32_t            v;
    /* This thread is going to load 4 bytes. Next thread in x will load
    the next 4 to be aligned. In total we pick up 32*4 = 128 bytes in this
    row of 32 (warp) for bit0.
    The next row (warp) is going to pick up bit1, etc
    The first grid starts at byte 0 + blockIdx.x * 2048
    The second grid starts at byte 8192/32/2
     */
    smem[threadIdx.y][threadIdx.x] =
        in[threadIdx.x +        // Aligned loads. 32*4 = 128 bytes
           threadIdx.y * 32 +   // Offset to next bit = 8192/32/4.
           blockIdx.x * 2048 +  // Start of the block
           blockIdx.y * 1024];  // Next 32 reads
    __syncthreads();            /* Now we loaded 4 kB to smem.   Do the first level of transpose */
    v = smem[threadIdx.y][threadIdx.x];
#pragma unroll 32
    for (int i = 0; i < 32; i++) smem[threadIdx.y][i] = __ballot_sync(0xFFFFFFFFU, v & (1U << i));
    __syncthreads(); /* Now we loaded 4 kB to smem.   Do the first level of transpose */
    out[threadIdx.x + threadIdx.y * 32 + blockIdx.y * 1024 + blockIdx.x * 2048] = smem[threadIdx.x][threadIdx.y];

    __shared__ uint32_t bitflagArr[8];
    __shared__ uint32_t  byteFlagArray[256];
    if (threadIdx.x * 4 < 32) {
        for (int i = 1; i < 4; i++) { smem[threadIdx.x * 4][threadIdx.y] |= smem[threadIdx.x * 4 + i][threadIdx.y]; }
        byteFlagArray[threadIdx.y * 8 + threadIdx.x] = (smem[threadIdx.x * 4][threadIdx.y] > 0);
    }
    __syncthreads();
    uint32_t buffer;
    if (threadIdx.y < 8) {
        buffer                  = byteFlagArray[threadIdx.y * 32 + threadIdx.x];
        bitflagArr[threadIdx.y] = __ballot_sync(0xFFFFFFFFU, buffer);
    }
    __syncthreads();
    if (threadIdx.y < 8) {
        d_byteFlagArray[blockIdx.x * 512 + blockIdx.y * 256 + threadIdx.y * 32 + threadIdx.x] =
            byteFlagArray[threadIdx.y * 32 + threadIdx.x];
    }
    if (threadIdx.x < 8 && threadIdx.y == 0) {
        d_bitFlagArray[blockIdx.x * 16 + blockIdx.y * 8 + threadIdx.x] = bitflagArr[threadIdx.x];
    }
}

__global__ void halfBitshuffleDebug(const uint32_t* __restrict__ in, uint32_t* __restrict__ out)
{
    /*
    grid 32x32 threads
    each thread loads 4 bytes (aligned) = 128 bytes per row of 32
    total bytes loaded = 32x32x4 = 4096 bytes
                  x                y  z
    blocks = ( total_bytes / 8192, 2, 1 )
    */
    __shared__ uint32_t smem[32][33];
    uint32_t            v;
    /* This thread is going to load 4 bytes. Next thread in x will load
    the next 4 to be aligned. In total we pick up 32*4 = 128 bytes in this
    row of 32 (warp) for bit0.
    The next row (warp) is going to pick up bit1, etc
    The first grid starts at byte 0 + blockIdx.x * 2048
    The second grid starts at byte 8192/32/2
     */
    smem[threadIdx.y][threadIdx.x] =
        in[threadIdx.x +        // Aligned loads. 32*4 = 128 bytes
           threadIdx.y * 32 +   // Offset to next bit = 8192/32/4.
           blockIdx.x * 2048 +  // Start of the block
           blockIdx.y * 1024];  // Next 32 reads
    __syncthreads();            /* Now we loaded 4 kB to smem.   Do the first level of transpose */
    v = smem[threadIdx.y][threadIdx.x];
#pragma unroll 8
    for (int i = 0; i < 8; i++) smem[threadIdx.y][i] = __ballot_sync(0xFFFFFFFFU, v & (1U << i));
#pragma unroll 8
    for (int i = 16; i < 24; i++) smem[threadIdx.y][i] = __ballot_sync(0xFFFFFFFFU, v & (1U << i));
    int     quotient                                            = threadIdx.x / 4;
    int     reminder                                            = threadIdx.x % 4;
    uint8_t first                                               = *((uint8_t*)(&v));
    uint8_t third                                               = *((uint8_t*)(&v) + 2);
    *((uint8_t*)(&smem[threadIdx.y][8 + quotient]) + reminder)  = first;
    *((uint8_t*)(&smem[threadIdx.y][24 + quotient]) + reminder) = third;
    __syncthreads(); /* Now we loaded 4 kB to smem.   Do the first level of transpose */
    out[threadIdx.x + threadIdx.y * 32 + blockIdx.y * 1024 + blockIdx.x * 2048] = smem[threadIdx.x][threadIdx.y];
}

void runSzs(std::string fileName, int x, int y, int z, double eb)
{
    // auto len3 = dim3(3600, 1800, 1);
    auto len3     = dim3(x, y, z);
    int  fileSize = GetFileSize(fileName);
    auto len      = int(fileSize / sizeof(float));

    float*    data;
    float*    h_data;
    bool*     signum;
    uint16_t* quant;
    float     time_elapsed;

    // float preTime = 0;
    // float shuffleTime = 0;
    // float encodeTime = 0;

    h_data = read_binary_to_new_array<float>(fileName, len);
    float range = *std::max_element(h_data , h_data + len) - *std::min_element(h_data , h_data + len);
    CHECK_CUDA(cudaMalloc((void**)&data, sizeof(float) * len));
    CHECK_CUDA(cudaMemcpy(data, h_data, sizeof(float) * len, cudaMemcpyHostToDevice));
    // CHECK_CUDA(cudaMemset(data, 0, sizeof(float) * len));
    CHECK_CUDA(cudaMalloc((void**)&quant, sizeof(uint16_t) * len));
    CHECK_CUDA(cudaMemset(quant, 0, sizeof(uint16_t) * len));
    CHECK_CUDA(cudaMalloc((void**)&signum, sizeof(bool) * len));

    cudaStream_t stream;
    cudaStreamCreate(&stream);
    // thrust::cuda::par.on(stream);

    // absolute error bound
    cusz::experimental::launch_construct_LorenzoI_var<float, uint16_t, float>(
        data, quant, signum, len3, eb * range, time_elapsed, stream);

    CHECK_CUDA(cudaFree(data));
    CHECK_CUDA(cudaFree(signum));

    uint16_t* bitshuffleOut;
    CHECK_CUDA(cudaMalloc((void**)&bitshuffleOut, sizeof(uint16_t) * len));
    CHECK_CUDA(cudaMemcpy(bitshuffleOut, quant, sizeof(uint16_t) * len, cudaMemcpyDeviceToDevice));

    int  blockSize    = 16;
    auto newLen       = len * 2;  // bitshuffle result length in byte unit
    newLen            = newLen % 8192 == 0 ? newLen : newLen - newLen % 8192 + 8192;
    int dataChunkSize = newLen % (blockSize * UINT32_BIT_LEN) == 0 ? newLen / (blockSize * UINT32_BIT_LEN)
                                                                   : int(newLen / (blockSize * UINT32_BIT_LEN)) + 1;

    // uint8_t* quantUint8 = (uint8_t*) quant;
    // newLen = len * 2;
    // CHECK_CUDA(cudaMemset(quantUint8 + newLen, 0, dataChunkSize * blockSize * UINT32_BIT_LEN - newLen));
    uint32_t* d_bitFlagArray;
    uint32_t*  d_byteFlagArray;

    uint8_t* d_out;
    CHECK_CUDA(cudaMalloc((void**)&d_bitFlagArray, sizeof(uint32_t) * dataChunkSize));
    CHECK_CUDA(cudaMemset(d_bitFlagArray, 0, sizeof(uint32_t) * dataChunkSize));
    CHECK_CUDA(cudaMalloc((void**)&d_byteFlagArray, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN));
    CHECK_CUDA(cudaMemset(d_byteFlagArray, 0, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN));

    CHECK_CUDA(cudaMalloc((void**)&d_out, sizeof(uint8_t) * dataChunkSize * blockSize * UINT32_BIT_LEN));
    CHECK_CUDA(cudaMemset(d_out, 0, sizeof(uint8_t) * dataChunkSize * blockSize * UINT32_BIT_LEN));
    // floor(sizeof(uint16_t) * len / 32 / 16)

    dim3 threads(32, 32);
    dim3 grid(floor(newLen / 8192), 2, 1);  // divided by 2 is because the file is transformed from uint32 to uint16
    bitshuffleAndBitflag<<<grid, threads>>>(
        (uint32_t*)quant, (uint32_t*)bitshuffleOut, blockSize, d_bitFlagArray, d_byteFlagArray);
    CHECK_CUDA(cudaFree(quant));

    newLen        = len * 2;  // bitshuffle result length in byte unit
    dataChunkSize = newLen % (blockSize * UINT32_BIT_LEN) == 0 ? newLen / (blockSize * UINT32_BIT_LEN)
                                                               : int(newLen / (blockSize * UINT32_BIT_LEN)) + 1;
    // uint8_t* tmp = (uint8_t*)malloc(sizeof(uint8_t) * dataChunkSize * UINT32_BIT_LEN);
    // CHECK_CUDA(cudaMemcpy(tmp, d_byteFlagArray,
    //                            sizeof(uint8_t) * dataChunkSize * UINT32_BIT_LEN, cudaMemcpyDeviceToHost));
    // // for(int i = 809885; i < 810016; i ++) {
    // //     printf("index %d: %d\n", i, tmp[i]);
    // // }
    // write_array_to_binary<uint8_t>("test.szs", tmp, dataChunkSize * UINT32_BIT_LEN);
    // free(tmp);
    uint32_t* d_preSumArray;
    CHECK_CUDA(
        cudaMalloc((void**)&d_preSumArray, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN + sizeof(uint32_t)));
    CHECK_CUDA(cudaMemset(d_preSumArray, 0, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN + sizeof(uint32_t)));
    uint32_t* d_byteFlagArrayTest;
    CHECK_CUDA(cudaMalloc((void**)&d_byteFlagArrayTest, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN));
    // CHECK_CUDA(cudaMemset(d_byteFlagArrayTest, 0, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN));
    // dataCast<<<dataChunkSize, 32>>>(d_byteFlagArray, d_byteFlagArrayTest);
    CHECK_CUDA(cudaMemcpy(
        d_byteFlagArrayTest, d_byteFlagArray, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN,
        cudaMemcpyDeviceToDevice));
    // uint8_t* baseByteArr = read_binary_to_new_array<uint8_t>("base.szs", dataChunkSize * UINT32_BIT_LEN);
    // CHECK_CUDA(cudaMemcpy(d_byteFlagArrayTest, baseByteArr, dataChunkSize * UINT32_BIT_LEN,
    // cudaMemcpyHostToDevice)); delete [] baseByteArr;
    CHECK_CUDA(cudaFree(d_byteFlagArray));

    // generateBitFlagArrayDebug<<<dataChunkSize, 32>>>(blockSize, (uint8_t*)bitshuffleOut, d_bitFlagArray,
    // d_byteFlagArray); Determine temporary device storage requirements
    void*  d_temp_storage     = NULL;
    size_t temp_storage_bytes = 0;
    cub::DeviceScan::ExclusiveSum(
        d_temp_storage, temp_storage_bytes, d_byteFlagArrayTest, d_preSumArray, dataChunkSize * UINT32_BIT_LEN);
    // Allocate temporary storage
    CHECK_CUDA(cudaMalloc(&d_temp_storage, temp_storage_bytes));
    // Run exclusive prefix sum
    cub::DeviceScan::ExclusiveSum(
        d_temp_storage, temp_storage_bytes, d_byteFlagArrayTest, d_preSumArray, dataChunkSize * UINT32_BIT_LEN);
    // d_out s<-- [0, 8, 14, 21, 26, 29, 29]
    // uint32_t* h_tmp = (uint32_t*)malloc(sizeof(uint32_t) * 100);
    // CHECK_CUDA(cudaMemcpy(h_tmp, d_preSumArray + dataChunkSize * UINT32_BIT_LEN - 100, sizeof(uint32_t) * 100, cudaMemcpyDeviceToHost));
    // for(int i = 0; i < 100; i++) {
    //     printf("index %d: %d\n", i, h_tmp[i]);
    // }
    // free(h_tmp);
    uint32_t* lastSum = (uint32_t*)malloc(sizeof(uint32_t));
    CHECK_CUDA(
        cudaMemcpy(lastSum, d_preSumArray + dataChunkSize * UINT32_BIT_LEN - 1, sizeof(uint32_t), cudaMemcpyDeviceToHost));
    uint32_t* lastFlag = (uint32_t*)malloc(sizeof(uint32_t));
    CHECK_CUDA(
        cudaMemcpy(lastFlag, d_byteFlagArrayTest + dataChunkSize * UINT32_BIT_LEN - 1, sizeof(uint32_t), cudaMemcpyDeviceToHost));
    uint32_t* result = (uint32_t*)malloc(sizeof(uint32_t));
    *result = *lastSum + *lastFlag;
    CHECK_CUDA(
        cudaMemcpy(d_preSumArray + dataChunkSize * UINT32_BIT_LEN, result, sizeof(uint32_t), cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaFree(d_byteFlagArrayTest));
    CHECK_CUDA(cudaFree(d_temp_storage));
    // dataChunkSize = (newLen - (newLen % 8192)) / (blockSize * UINT32_BIT_LEN);
    encodeDebug<<<dataChunkSize, 32>>>(
        blockSize, (uint8_t*)bitshuffleOut, d_out, d_preSumArray);  // floor(sizeof(uint16_t) * len / 32)

    // // print debug info
    // uint32_t *h_result = (uint32_t*)malloc(sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN + 1);
    // CHECK_CUDA(cudaMemcpy(h_result, d_preSumArray, sizeof(uint32_t) * dataChunkSize * UINT32_BIT_LEN + 1,
    // cudaMemcpyDeviceToHost)); for(int i = 0; i < 100; i++) {
    //     printf("index %d: %d\n", i, h_result[i]);
    // }
    // free(h_result);
    // uint32_t* result = (uint32_t*)malloc(sizeof(uint32_t));
    // CHECK_CUDA(
    //     cudaMemcpy(result, d_preSumArray + dataChunkSize * UINT32_BIT_LEN, sizeof(uint32_t), cudaMemcpyDeviceToHost));
    printf("original size: %d\n", fileSize);
    printf("compressed size: %d\n", sizeof(uint32_t) * dataChunkSize + blockSize * (*result));
    printf(
        "compression ratio: %f\n", float(fileSize) / float(sizeof(uint32_t) * dataChunkSize + blockSize * (*result)));
    cudaStreamDestroy(stream);
    CHECK_CUDA(cudaFree(bitshuffleOut));
    CHECK_CUDA(cudaFree(d_bitFlagArray));
    CHECK_CUDA(cudaFree(d_preSumArray));
    CHECK_CUDA(cudaFree(d_out));
    delete[] h_data;
    free(result);
    free(lastSum);
    free(lastFlag);
    return;
}

int main(int argc, char* argv[])
{
    using T = float;
    std::string dir_name;
    dir_name  = std::string(argv[1]);
    int    x  = std::stoi(argv[2]);
    int    y  = std::stoi(argv[3]);
    int    z  = std::stoi(argv[4]);
    double eb = std::stod(argv[5]);

    // iterate the dir to get file with .dat and .f32 to compress
    struct dirent* entry      = nullptr;
    DIR*           dp         = nullptr;
    std::string    extension1 = ".dat";
    std::string    extension2 = ".f32";
    std::string    fname;

    dp = opendir(dir_name.c_str());
    if (dp != nullptr) {
        while ((entry = readdir(dp))) {
            fname = entry->d_name;
            if (fname.find(extension1, (fname.length() - extension1.length())) != std::string::npos ||
                fname.find(extension2, (fname.length() - extension2.length())) != std::string::npos) {
                printf("%s\n", entry->d_name);
                // std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
                runSzs(dir_name + "/" + fname, x, y, z, eb);
                // std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();

                // std::cout << "Time difference = " << std::chrono::duration_cast<std::chrono::microseconds>(end -
                // begin).count() << "[µs]" << std::endl; std::cout << "Time difference = " <<
                // std::chrono::duration_cast<std::chrono::nanoseconds> (end - begin).count() << "[ns]" << std::endl;
            }
        }
    }
    closedir(dp);
    return 0;
}

// int main(int argc, char *argv[])
// {
//   using T = float;
//   std::string dir_name;
//   dir_name = std::string(argv[1]);
//   int x = std::stoi(argv[2]);
//   int y = std::stoi(argv[3]);
//   int z = std::stoi(argv[4]);
//   double eb = std::stod(argv[5]);
//   runSzs(dir_name, x, y, z, eb);
// //   // iterate the dir to get file with .dat and .f32 to compress
// //   struct dirent *entry = nullptr;
// //   DIR *dp = nullptr;
// //   std::string extension1 = ".dat";
// //   std::string extension2 = ".f32";
// //   std::string fname;

// //   dp = opendir(dir_name.c_str());
// //   if (dp != nullptr) {
// //     while ((entry = readdir(dp))){
// //       fname = entry->d_name;
// //       if(fname.find(extension1, (fname.length() - extension1.length())) != std::string::npos ||
// //           fname.find(extension2, (fname.length() - extension2.length())) != std::string::npos){
// //         printf ("%s\n", entry->d_name);
// //         // std::chrono::steady_clock::time_point begin = std::chrono::steady_clock::now();
// //         runSzs(dir_name + "/" + fname, x, y, z, eb);
// //         // std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now();

// //         // std::cout << "Time difference = " << std::chrono::duration_cast<std::chrono::microseconds>(end -
// begin).count() << "[µs]" << std::endl;
// //         // std::cout << "Time difference = " << std::chrono::duration_cast<std::chrono::nanoseconds> (end -
// begin).count() << "[ns]" << std::endl;
// //       }
// //     }
// //   }
// //   closedir(dp);
//   return 0;
// }