#include "../header/mpi_nccl_communication.h"

static const ncclDataType_t TYPE2TYPE_V1[] = {
    ncclChar,    // ncclInt8, ncclChar
    ncclUint8,   // ncclUint8
    ncclInt32,   // ncclInt32, ncclInt
    ncclUint32,  // ncclUint32
    ncclInt64,   // ncclInt64
    ncclUint64,  // ncclUint64
    ncclFloat16, // ncclFloat16, ncclHalf
    ncclFloat32, // ncclFloat32, ncclFloat
    ncclFloat64  // ncclFloat64, ncclDouble
};

ncclDataType_t _get_proper_datatype(int datatype) {
    return TYPE2TYPE_V1[datatype];
}

static const ncclRedOp_t TYPE2TYPE_V2[] = {ncclSum, ncclProd, ncclMax, ncclMin};

ncclRedOp_t _get_proper_redop(int redop) {
    return TYPE2TYPE_V2[redop];
}

void MPIInit() {
    MPICHECK(MPI_Init(NULL, NULL));
}

void MPIFinalize() {
    MPICHECK(MPI_Finalize());
}

void MPIGetComm(MPI_Comm *comm) {
    *comm = MPI_COMM_WORLD;
}

void MPIBcast(void *buffer, int size, MPI_Datatype datatype, int root,
              MPI_Comm comm) {
    MPICHECK(MPI_Bcast(buffer, size, datatype, root, comm));
}

void getMPICommRank(MPI_Comm *comm, int *myRank) {
    MPICHECK(MPI_Comm_rank(*comm, myRank));
}

void getMPICommSize(MPI_Comm *comm, int *nRanks) {
    MPICHECK(MPI_Comm_size(*comm, nRanks));
}

uint64_t getHostHash(const char *string) {
    // Based on DJB2, result = result * 33 + char
    uint64_t result = 5381;
    for (int c = 0; string[c] != '\0'; c++) {
        result = ((result << 5) + result) + string[c];
    }
    return result;
}

void getHostName(char *hostname, int maxlen) {
    gethostname(hostname, maxlen);
    for (int i = 0; i < maxlen; i++) {
        if (hostname[i] == '.') {
            hostname[i] = '\0';
            return;
        }
    }
}

void getLocalRank(MPI_Comm *comm, int nRanks, int myRank, int *localRank,
                  unsigned long long hostHashs[]) {
    int _localRank = 0;
    char hostname[1024];
    getHostName(hostname, 1024);
    hostHashs[myRank] = getHostHash(hostname);
    MPICHECK(MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, hostHashs,
                           sizeof(unsigned long long), MPI_BYTE, *comm));
    for (int p = 0; p < nRanks; p++) {
        if (p == myRank)
            break;
        if (hostHashs[p] == hostHashs[myRank])
            (_localRank)++;
    }
    *localRank = _localRank;
}

void getGlobalDevice(MPI_Comm *comm, int nRanks, int myRank, int device_id,
                     int hostDevices[]) {
    hostDevices[myRank] = device_id;
    MPICHECK(MPI_Allgather(MPI_IN_PLACE, 0, MPI_DATATYPE_NULL, hostDevices,
                           sizeof(int), MPI_BYTE, *comm));
}

void setDevice(int device_id) {
    CUDACHECK(cudaSetDevice(device_id));
}

void getNcclUniqueId(ncclUniqueId *Id, MPI_Comm mpi_comm, int localRank,
                     int senderRank) {
    if (localRank == 0)
        NCCLCHECK(ncclGetUniqueId(Id));
    MPIBcast((void *)Id, sizeof(ncclUniqueId), MPI_BYTE, senderRank, mpi_comm);
}

void getGroupNcclUniqueId(ncclUniqueId *Id, MPI_Comm mpi_comm, int rank,
                          int dests[], int group_size, int group_id) {
    // we assume that group size >= 2
    if (dests[0] == rank) {
        NCCLCHECK(ncclGetUniqueId(Id));
        for (int i = 1; i < group_size; ++i) {
            MPICHECK(MPI_Send((const void *)Id, sizeof(ncclUniqueId), MPI_BYTE,
                              dests[i], group_id, mpi_comm));
        }
    } else {
        MPICHECK(MPI_Recv((void *)Id, sizeof(ncclUniqueId), MPI_BYTE, dests[0],
                          group_id, mpi_comm, MPI_STATUS_IGNORE));
    }
}

void initNcclCommRank(ncclComm_t *comm, int nranks, ncclUniqueId *commId,
                      int rank, int localRank) {
    NCCLCHECK(ncclCommInitRank(comm, nranks, *commId, rank));
}

void _ncclAllReduce(const void *sendbuff, void *recvbuff, int size,
                    int datatype, int op, ncclComm_t comm,
                    cudaStream_t stream) {
    NCCLCHECK(ncclAllReduce((const void *)sendbuff, (void *)recvbuff, size,
                            _get_proper_datatype(datatype),
                            _get_proper_redop(op), comm, stream));
}

void _ncclBroadcast(const void *sendbuff, void *recvbuff, int size,
                    int datatype, int root, ncclComm_t comm,
                    cudaStream_t stream) {
    NCCLCHECK(ncclBroadcast((const void *)sendbuff, (void *)recvbuff, size,
                            _get_proper_datatype(datatype), root, comm,
                            stream));
}

void _ncclAllGather(const void *sendbuff, void *recvbuff, int size,
                    int datatype, ncclComm_t comm, cudaStream_t stream) {
    NCCLCHECK(ncclAllGather((const void *)sendbuff, (void *)recvbuff, size,
                            _get_proper_datatype(datatype), comm, stream));
}

void _ncclSend(const void *sendbuff, int size, int datatype, int target,
               ncclComm_t comm, cudaStream_t stream) {
    NCCLCHECK(ncclSend(sendbuff, size, _get_proper_datatype(datatype), target,
                       comm, stream));
}

void _ncclRecv(void *recvbuff, int size, int datatype, int src, ncclComm_t comm,
               cudaStream_t stream) {
    NCCLCHECK(ncclRecv(recvbuff, size, _get_proper_datatype(datatype), src,
                       comm, stream));
}

void dlarrayAllReduce(DLArray *input_array, DLArray *output_array, int datatype,
                      int op, ncclComm_t comm, DLStreamHandle stream_handle) {
    int size = 1;
    for (int i = 0; i < input_array->ndim; i++) {
        size = size * input_array->shape[i];
    }
    float *input_data_buffer = (float *)(input_array->data);
    float *output_data_buffer = (float *)(output_array->data);
    cudaStream_t stream = *(cudaStream_t *)stream_handle->handle;
    _ncclAllReduce(input_data_buffer, output_data_buffer, size, datatype, op,
                   comm, stream);
}

void dlarrayBroadcast(DLArray *input_array, DLArray *output_array, int datatype,
                      int root, ncclComm_t comm, DLStreamHandle stream_handle) {
    int size = 1;
    for (int i = 0; i < input_array->ndim; i++) {
        size = size * input_array->shape[i];
    }
    float *input_data_buffer = (float *)(input_array->data);
    float *output_data_buffer = (float *)(output_array->data);
    cudaStream_t stream = *(cudaStream_t *)stream_handle->handle;
    _ncclBroadcast(input_data_buffer, output_data_buffer, size, datatype, root,
                   comm, stream);
}

void dlarrayAllGather(DLArray *array, DLArray *output_array, int datatype,
                      ncclComm_t comm, DLStreamHandle stream_handle) {
    int size = 1;
    for (int i = 0; i < array->ndim; i++) {
        size = size * array->shape[i];
    }
    int output_size = 1;
    for (int i = 0; i < output_array->ndim; i++) {
        output_size = output_size * output_array->shape[i];
    }
    float *input_buffer = (float *)(array->data);
    float *output_buffer = (float *)(output_array->data);
    cudaStream_t stream = *(cudaStream_t *)stream_handle->handle;
    _ncclAllGather(input_buffer, output_buffer, size, datatype, comm, stream);
}

void dlarraySend(DLArray *array, int datatype, int target, ncclComm_t comm,
                 DLStreamHandle stream_handle) {
    int size = 1;
    for (int i = 0; i < array->ndim; i++) {
        size = size * array->shape[i];
    }
    float *data_buffer = (float *)(array->data);
    cudaStream_t stream = *(cudaStream_t *)stream_handle->handle;

    _ncclSend(data_buffer, size, datatype, target, comm, stream);
}

void dlarrayRecv(DLArray *array, int datatype, int src, ncclComm_t comm,
                 DLStreamHandle stream_handle) {
    int size = 1;
    for (int i = 0; i < array->ndim; i++) {
        size = size * array->shape[i];
    }
    float *data_buffer = (float *)(array->data);
    cudaStream_t stream = *(cudaStream_t *)stream_handle->handle;

    _ncclRecv(data_buffer, size, datatype, src, comm, stream);
}

void commDestroyNccl(ncclComm_t *comm) {
    NCCLCHECK(ncclCommDestroy(*comm));
}

void display(const float *device_data, int dev_id, int size) {
    printf("Display Device %d:\n", dev_id);
    CUDACHECK(cudaSetDevice(dev_id));
    float *host_buff;
    CUDACHECK(
        cudaHostAlloc(&host_buff, size * sizeof(float), cudaHostAllocDefault));
    CUDACHECK(cudaMemcpy(host_buff, device_data, size * sizeof(float),
                         cudaMemcpyDeviceToHost));
    for (int i = 0; i < size; i++) {
        printf("%f ", host_buff[i]);
    }
    printf("\n");
    CUDACHECK(cudaFreeHost(host_buff));
}

void print_array(float *array, int size) {
    float *output;
    output = (float *)malloc(sizeof(float) * size);
    cudaMemcpy(output, array, size * sizeof(float), cudaMemcpyHostToHost);
    for (int i = 0; i < size; i++) {
        printf("%f ", output[i]);
    }
    printf("\n");
}
