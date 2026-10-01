#ifndef STEAMOS_WAYDROID_BINDER_DEPS_H
#define STEAMOS_WAYDROID_BINDER_DEPS_H

struct ipc_namespace;

int binder_deps_init(void);
struct ipc_namespace *binder_get_init_ipc_ns(void);

#endif
