#include <linux/cred.h>
#include <linux/errno.h>
#include <linux/fdtable.h>
#include <linux/file.h>
#include <linux/ipc_namespace.h>
#include <linux/kprobes.h>
#include <linux/list_lru.h>
#include <linux/mm.h>
#include <linux/mmap_lock.h>
#include <linux/sched.h>
#include <linux/security.h>
#include <linux/task_work.h>
#include <linux/wait.h>

#include "deps.h"

#ifndef CONFIG_KPROBES
#error "Valve Binder external module requires CONFIG_KPROBES"
#endif

typedef unsigned long (*kallsyms_lookup_name_t)(const char *name);

static int lookup_kprobe_handler(struct kprobe *probe, struct pt_regs *regs)
{
	return 0;
}

static kallsyms_lookup_name_t get_kallsyms_lookup_name(void)
{
	struct kprobe probe = {
		.symbol_name = "kallsyms_lookup_name",
		.pre_handler = lookup_kprobe_handler,
	};
	kallsyms_lookup_name_t lookup;
	int ret;

	ret = register_kprobe(&probe);
	if (ret)
		return NULL;

	lookup = (kallsyms_lookup_name_t)probe.addr;
	unregister_kprobe(&probe);

	return lookup;
}

static void (*__wake_up_pollfree_ptr)(struct wait_queue_head *wq_head);
static int (*can_nice_ptr)(const struct task_struct *p, const int nice);
static struct file *(*file_close_fd_ptr)(unsigned int fd);
static struct ipc_namespace *init_ipc_ns_ptr;
static bool (*list_lru_add_ptr)(struct list_lru *lru, struct list_head *item,
				int nid, struct mem_cgroup *memcg);
static bool (*list_lru_del_ptr)(struct list_lru *lru, struct list_head *item,
				int nid, struct mem_cgroup *memcg);
static struct vm_area_struct *(*lock_vma_under_rcu_ptr)(
	struct mm_struct *mm, unsigned long address);
static void (*put_ipc_ns_ptr)(struct ipc_namespace *ns);
static int (*security_binder_set_context_mgr_ptr)(const struct cred *mgr);
static int (*security_binder_transaction_ptr)(const struct cred *from,
					       const struct cred *to);
static int (*security_binder_transfer_binder_ptr)(const struct cred *from,
						   const struct cred *to);
static int (*security_binder_transfer_file_ptr)(const struct cred *from,
						 const struct cred *to,
						 const struct file *file);
static int (*task_work_add_ptr)(struct task_struct *task,
				struct callback_head *twork,
				enum task_work_notify_mode mode);
static void (*zap_page_range_single_ptr)(struct vm_area_struct *vma,
					  unsigned long address,
					  unsigned long size,
					  struct zap_details *details);

#define RESOLVE_FUNCTION(lookup, name)					\
	do {								\
		name##_ptr = (typeof(name##_ptr))(lookup)(#name);	\
		if (!name##_ptr) {					\
			pr_err("binder_linux: cannot resolve %s\n", #name); \
			return -ENOENT;					\
		}							\
	} while (0)

int binder_deps_init(void)
{
	kallsyms_lookup_name_t lookup;

	lookup = get_kallsyms_lookup_name();
	if (!lookup) {
		pr_err("binder_linux: cannot resolve kallsyms_lookup_name via kprobe\n");
		return -ENOENT;
	}

	RESOLVE_FUNCTION(lookup, __wake_up_pollfree);
	RESOLVE_FUNCTION(lookup, can_nice);
	RESOLVE_FUNCTION(lookup, file_close_fd);
	RESOLVE_FUNCTION(lookup, list_lru_add);
	RESOLVE_FUNCTION(lookup, list_lru_del);
	RESOLVE_FUNCTION(lookup, lock_vma_under_rcu);
	RESOLVE_FUNCTION(lookup, put_ipc_ns);
	RESOLVE_FUNCTION(lookup, security_binder_set_context_mgr);
	RESOLVE_FUNCTION(lookup, security_binder_transaction);
	RESOLVE_FUNCTION(lookup, security_binder_transfer_binder);
	RESOLVE_FUNCTION(lookup, security_binder_transfer_file);
	RESOLVE_FUNCTION(lookup, task_work_add);
	RESOLVE_FUNCTION(lookup, zap_page_range_single);

	init_ipc_ns_ptr = (struct ipc_namespace *)lookup("init_ipc_ns");
	if (!init_ipc_ns_ptr) {
		pr_err("binder_linux: cannot resolve init_ipc_ns\n");
		return -ENOENT;
	}

	pr_info("binder_linux: resolved external Binder kernel dependencies\n");
	return 0;
}

struct ipc_namespace *binder_get_init_ipc_ns(void)
{
	return init_ipc_ns_ptr;
}

void __wake_up_pollfree(struct wait_queue_head *wq_head)
{
	__wake_up_pollfree_ptr(wq_head);
}

int can_nice(const struct task_struct *p, const int nice)
{
	return can_nice_ptr(p, nice);
}

struct file *file_close_fd(unsigned int fd)
{
	return file_close_fd_ptr(fd);
}

bool list_lru_add(struct list_lru *lru, struct list_head *item, int nid,
		  struct mem_cgroup *memcg)
{
	return list_lru_add_ptr(lru, item, nid, memcg);
}

bool list_lru_del(struct list_lru *lru, struct list_head *item, int nid,
		  struct mem_cgroup *memcg)
{
	return list_lru_del_ptr(lru, item, nid, memcg);
}

struct vm_area_struct *lock_vma_under_rcu(struct mm_struct *mm,
					  unsigned long address)
{
	return lock_vma_under_rcu_ptr(mm, address);
}

void put_ipc_ns(struct ipc_namespace *ns)
{
	put_ipc_ns_ptr(ns);
}

int security_binder_set_context_mgr(const struct cred *mgr)
{
	return security_binder_set_context_mgr_ptr(mgr);
}

int security_binder_transaction(const struct cred *from, const struct cred *to)
{
	return security_binder_transaction_ptr(from, to);
}

int security_binder_transfer_binder(const struct cred *from,
				    const struct cred *to)
{
	return security_binder_transfer_binder_ptr(from, to);
}

int security_binder_transfer_file(const struct cred *from,
				  const struct cred *to,
				  const struct file *file)
{
	return security_binder_transfer_file_ptr(from, to, file);
}

int task_work_add(struct task_struct *task, struct callback_head *twork,
		  enum task_work_notify_mode mode)
{
	return task_work_add_ptr(task, twork, mode);
}

void zap_page_range_single(struct vm_area_struct *vma, unsigned long address,
			   unsigned long size, struct zap_details *details)
{
	zap_page_range_single_ptr(vma, address, size, details);
}
