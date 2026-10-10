#include "../functional/test_utils.h"
#include "bench_utils.h"

#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv)
{
    const char* first_path = nullptr;
    const char* second_path = nullptr;
    int gpu_id = 0;
    unsigned iterations = 1024;
    int opt;
    while ((opt = getopt(argc, argv, "f:F:d:n:")) != -1) {
        if (opt == 'f') first_path = optarg;
        else if (opt == 'F') second_path = optarg;
        else if (opt == 'd') gpu_id = atoi(optarg);
        else if (opt == 'n') iterations = static_cast<unsigned>(atoi(optarg));
        else return 1;
    }
    if (!first_path || !second_path || strcmp(first_path, second_path) == 0 ||
        iterations == 0) {
        fprintf(stderr, "Usage: %s -f <device0> -F <device1> [-d gpu_id] [-n reads]\n",
                argv[0]);
        return 1;
    }

    cudaSetDevice(gpu_id);
    if (uGDSDriverOpen().err != UGDS_SUCCESS) return 1;
    uGDSHandle_t first = open_handle_at(first_path);
    uGDSHandle_t second = open_handle_at(second_path);
    if (!first || !second) {
        close_handle(first);
        close_handle(second);
        uGDSDriverClose();
        return 1;
    }

    uGDSStorage_t storage = nullptr;
    if (uGDSStorageCreate(&storage).err != UGDS_SUCCESS ||
        uGDSStorageAddHandle(storage, first).err != UGDS_SUCCESS ||
        uGDSStorageAddHandle(storage, second).err != UGDS_SUCCESS) {
        uGDSStorageDestroy(storage);
        close_handle(first);
        close_handle(second);
        uGDSDriverClose();
        return 1;
    }

    uint32_t device_count = 0;
    uint64_t capacity = 0;
    uGDSStorageGetDeviceCount(storage, &device_count);
    uGDSStorageGetCapacity(storage, &capacity);
    printf("storage devices=%u aggregate_capacity_bytes=%llu\n",
           device_count, (unsigned long long)capacity);

    uGDSHandle_t storage_first = nullptr;
    uGDSHandle_t storage_second = nullptr;
    if (uGDSStorageGetHandle(storage, 0, &storage_first).err != UGDS_SUCCESS ||
        uGDSStorageGetHandle(storage, 1, &storage_second).err != UGDS_SUCCESS) {
        uGDSStorageDestroy(storage);
        close_handle(first);
        close_handle(second);
        uGDSDriverClose();
        return 1;
    }

    void* first_buffer = nullptr;
    void* second_buffer = nullptr;
    bool first_registered = false;
    bool second_registered = false;
    if (cudaMalloc(&first_buffer, 65536) == cudaSuccess &&
        cudaMalloc(&second_buffer, 65536) == cudaSuccess) {
        first_registered =
            uGDSBufRegister(first_buffer, 65536, TEST_BUF_FLAGS).err == UGDS_SUCCESS;
        second_registered =
            uGDSBufRegister(second_buffer, 65536, TEST_BUF_FLAGS).err == UGDS_SUCCESS;
    }
    if (!first_registered || !second_registered) {
        if (first_registered) uGDSBufDeregister(first_buffer);
        if (second_registered) uGDSBufDeregister(second_buffer);
        if (first_buffer) cudaFree(first_buffer);
        if (second_buffer) cudaFree(second_buffer);
        uGDSStorageDestroy(storage);
        close_handle(first);
        close_handle(second);
        uGDSDriverClose();
        return 1;
    }

    /* Test concurrent read performance */
    Worker first_worker = {storage_first, first_buffer, iterations, 0, 0,
                           "device0", false, 0, 0};
    Worker second_worker = {storage_second, second_buffer, iterations, 0, 0,
                            "device1", false, 0, 0};
    pthread_t first_thread, second_thread;
    int first_rc = pthread_create(&first_thread, nullptr, read_worker, &first_worker);
    int second_rc = first_rc == 0 ?
        pthread_create(&second_thread, nullptr, read_worker, &second_worker) : -1;
    if (first_rc != 0 || second_rc != 0) {
        if (first_rc == 0) pthread_join(first_thread, nullptr);
        uGDSBufDeregister(first_buffer);
        uGDSBufDeregister(second_buffer);
        cudaFree(first_buffer);
        cudaFree(second_buffer);
        uGDSStorageDestroy(storage);
        close_handle(first);
        close_handle(second);
        uGDSDriverClose();
        return 1;
    }
    /* The main thread waits for both read threads to complete. */
    pthread_join(first_thread, nullptr);
    pthread_join(second_thread, nullptr);
    report_worker_failure(first_worker);
    report_worker_failure(second_worker);
    printf("device0 reads=%u elapsed_ms=%.3f\n", first_worker.completed,
           first_worker.elapsed_ns / 1000000.0);
    printf("device1 reads=%u elapsed_ms=%.3f\n", second_worker.completed,
           second_worker.elapsed_ns / 1000000.0);

    uGDSBufDeregister(first_buffer);
    uGDSBufDeregister(second_buffer);
    cudaFree(first_buffer);
    cudaFree(second_buffer);
    uGDSStorageDestroy(storage);
    close_handle(first);
    close_handle(second);
    uGDSDriverClose();
    return 0;
}
