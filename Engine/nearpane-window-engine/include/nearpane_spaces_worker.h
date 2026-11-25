#ifndef NEARPANE_SPACES_WORKER_H
#define NEARPANE_SPACES_WORKER_H
#include "nearpane_window_engine.h"

/* Anonymous-pipe IPC for the one session-owning Spaces worker. Requests and
 * receipts preserve the shipping C ABI. There is no window-ID recovery service. */
enum { NP_SW_MAGIC = 0x4e505357, NP_SW_VERSION = 1 };
enum { NP_SW_READY = 0, NP_SW_SUBMIT = 1, NP_SW_POLL = 2, NP_SW_CANCEL = 3,
       NP_SW_REVOKE = 4, NP_SW_CLOSE = 5 };
typedef struct {
    uint32_t magic, version, operation, size;
    uint64_t serial, ticket;
    NPRequest request;
} NPSpacesWorkerRequest;
typedef struct {
    uint32_t magic, version, operation, size;
    uint64_t serial, ticket, epoch;
    uint32_t transport, reserved;
    NPReceipt receipt;
} NPSpacesWorkerReply;

static inline int np_spaces_worker_packet_valid(const NPSpacesWorkerRequest *p) {
    if (!p || p->magic != NP_SW_MAGIC || p->version != NP_SW_VERSION ||
        p->size != sizeof(*p) || p->operation < NP_SW_SUBMIT || p->operation > NP_SW_CLOSE) return 0;
    if (p->operation == NP_SW_REVOKE || p->operation == NP_SW_CANCEL)
        return p->serial == 0 && (p->operation != NP_SW_CANCEL || p->ticket > 0);
    if (p->serial == 0) return 0;
    if (p->operation == NP_SW_SUBMIT)
        return p->ticket == 0 && p->request.backend == NP_SPACES &&
            p->request.size == sizeof(NPRequest) && p->request.version == NP_ENGINE_ABI;
    return p->operation != NP_SW_POLL || p->ticket > 0;
}
#endif
