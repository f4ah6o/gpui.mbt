#define GPUI_ACCESSIBILITY_OWNER_ID_TEST 1
#include "../../accessibility/owner_id.c"

#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#define OWNER_ID_TEST_THREAD_COUNT 8
#define OWNER_ID_TEST_VALUES_PER_THREAD 4096

typedef struct owner_id_worker_context {
  uint64_t *ids;
  size_t offset;
  size_t count;
  HANDLE start_event;
} owner_id_worker_context;

static DWORD WINAPI owner_id_worker(void *opaque) {
  owner_id_worker_context *context = (owner_id_worker_context *)opaque;
  if (WaitForSingleObject(context->start_event, INFINITE) != WAIT_OBJECT_0) {
    return 1;
  }
  for (size_t index = 0; index < context->count; ++index) {
    context->ids[context->offset + index] =
        gpui_accessibility_next_owner_id();
  }
  return 0;
}
#else
#include <pthread.h>

#define OWNER_ID_TEST_THREAD_COUNT 8
#define OWNER_ID_TEST_VALUES_PER_THREAD 4096

typedef struct owner_id_worker_context {
  uint64_t *ids;
  size_t offset;
  size_t count;
} owner_id_worker_context;

static pthread_mutex_t owner_id_start_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t owner_id_start_condition = PTHREAD_COND_INITIALIZER;
static size_t owner_id_waiting_workers = 0;
static bool owner_id_start_workers = false;

static void owner_id_wait_for_start(void) {
  pthread_mutex_lock(&owner_id_start_mutex);
  ++owner_id_waiting_workers;
  pthread_cond_broadcast(&owner_id_start_condition);
  while (!owner_id_start_workers) {
    pthread_cond_wait(&owner_id_start_condition, &owner_id_start_mutex);
  }
  pthread_mutex_unlock(&owner_id_start_mutex);
}

static void *owner_id_worker(void *opaque) {
  owner_id_worker_context *context = (owner_id_worker_context *)opaque;
  owner_id_wait_for_start();
  for (size_t index = 0; index < context->count; ++index) {
    context->ids[context->offset + index] =
        gpui_accessibility_next_owner_id();
  }
  return NULL;
}
#endif

static int owner_id_compare(const void *left, const void *right) {
  const uint64_t left_value = *(const uint64_t *)left;
  const uint64_t right_value = *(const uint64_t *)right;
  return left_value < right_value ? -1 : left_value > right_value ? 1 : 0;
}

static int owner_id_test_exhaustion(void) {
  OWNER_COUNTER_ALIGN owner_counter_t boundary;
  if (((uintptr_t)&boundary % 8) != 0) {
    fprintf(stderr, "owner counter test state is not 8-byte aligned\n");
    return 1;
  }

  gpui_accessibility_owner_id_test_init_counter(&boundary, UINT64_MAX - 1);
  if (gpui_accessibility_owner_id_test_next_counter(&boundary) != UINT64_MAX - 1 ||
      gpui_accessibility_owner_id_test_next_counter(&boundary) != UINT64_MAX ||
      gpui_accessibility_owner_id_test_next_counter(&boundary) != 0 ||
      gpui_accessibility_owner_id_test_next_counter(&boundary) != 0) {
    fprintf(stderr, "owner counter wrapped or reused an ID after exhaustion\n");
    return 1;
  }
  return 0;
}

static int owner_id_test_concurrent_uniqueness(void) {
  const size_t total =
      (size_t)OWNER_ID_TEST_THREAD_COUNT * OWNER_ID_TEST_VALUES_PER_THREAD;
  uint64_t *ids = (uint64_t *)malloc(total * sizeof(*ids));
  if (ids == NULL) {
    fprintf(stderr, "could not allocate owner ID test output\n");
    return 1;
  }

  owner_id_worker_context contexts[OWNER_ID_TEST_THREAD_COUNT];
#if defined(_WIN32)
  HANDLE start_event = CreateEventW(NULL, TRUE, FALSE, NULL);
  HANDLE threads[OWNER_ID_TEST_THREAD_COUNT];
  if (start_event == NULL) {
    fprintf(stderr, "could not create owner ID test start event\n");
    free(ids);
    return 1;
  }
  size_t launched = 0;
  for (; launched < OWNER_ID_TEST_THREAD_COUNT; ++launched) {
    contexts[launched].ids = ids;
    contexts[launched].offset = launched * OWNER_ID_TEST_VALUES_PER_THREAD;
    contexts[launched].count = OWNER_ID_TEST_VALUES_PER_THREAD;
    contexts[launched].start_event = start_event;
    threads[launched] = CreateThread(
        NULL, 0, owner_id_worker, &contexts[launched], 0, NULL);
    if (threads[launched] == NULL) {
      fprintf(stderr, "could not start owner ID test worker\n");
      break;
    }
  }
  SetEvent(start_event);
  if (launched != OWNER_ID_TEST_THREAD_COUNT) {
    WaitForMultipleObjects((DWORD)launched, threads, TRUE, INFINITE);
    for (size_t index = 0; index < launched; ++index) {
      CloseHandle(threads[index]);
    }
    CloseHandle(start_event);
    free(ids);
    return 1;
  }
  const DWORD wait_result = WaitForMultipleObjects(
      OWNER_ID_TEST_THREAD_COUNT, threads, TRUE, INFINITE);
  for (size_t index = 0; index < OWNER_ID_TEST_THREAD_COUNT; ++index) {
    CloseHandle(threads[index]);
  }
  CloseHandle(start_event);
  if (wait_result != WAIT_OBJECT_0) {
    fprintf(stderr, "could not join owner ID test workers\n");
    free(ids);
    return 1;
  }
#else
  pthread_t threads[OWNER_ID_TEST_THREAD_COUNT];
  size_t launched = 0;
  for (; launched < OWNER_ID_TEST_THREAD_COUNT; ++launched) {
    contexts[launched].ids = ids;
    contexts[launched].offset = launched * OWNER_ID_TEST_VALUES_PER_THREAD;
    contexts[launched].count = OWNER_ID_TEST_VALUES_PER_THREAD;
    if (pthread_create(
            &threads[launched], NULL, owner_id_worker, &contexts[launched]) !=
        0) {
      fprintf(stderr, "could not start owner ID test worker\n");
      break;
    }
  }
  pthread_mutex_lock(&owner_id_start_mutex);
  while (owner_id_waiting_workers < launched) {
    pthread_cond_wait(&owner_id_start_condition, &owner_id_start_mutex);
  }
  owner_id_start_workers = true;
  pthread_cond_broadcast(&owner_id_start_condition);
  pthread_mutex_unlock(&owner_id_start_mutex);
  for (size_t index = 0; index < launched; ++index) {
    pthread_join(threads[index], NULL);
  }
  if (launched != OWNER_ID_TEST_THREAD_COUNT) {
    free(ids);
    return 1;
  }
#endif

  qsort(ids, total, sizeof(*ids), owner_id_compare);
  for (size_t index = 0; index < total; ++index) {
    if (ids[index] != (uint64_t)index + 1) {
      fprintf(stderr, "duplicate, missing, or invalid ID at sorted index %zu\n", index);
      free(ids);
      return 1;
    }
  }

  free(ids);
  return 0;
}

int main(void) {
  if (((uintptr_t)&owner_id_counter % 8) != 0) {
    fprintf(stderr, "global owner ID counter is not 8-byte aligned\n");
    return 1;
  }
  if (owner_id_test_exhaustion() != 0 ||
      owner_id_test_concurrent_uniqueness() != 0) {
    return 1;
  }
  puts("owner ID atomic uniqueness and exhaustion tests passed");
  return 0;
}
