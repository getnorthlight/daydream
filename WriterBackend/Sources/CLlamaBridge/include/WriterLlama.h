#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct wr_runtime wr_runtime;
typedef struct wr_load_ticket wr_load_ticket;
wr_load_ticket * wr_load_ticket_create(void);
void wr_load_ticket_cancel(wr_load_ticket *);
int wr_load_ticket_cancelled(wr_load_ticket *);
int wr_load_ticket_phase(wr_load_ticket *);
int wr_runtime_image_conflicts(const char * image, const char * library);
void wr_load_ticket_destroy(wr_load_ticket *);
typedef int (*wr_load_preflight)(void *);
int wr_load_attempt(wr_runtime *, const char *, const char *, wr_load_ticket *, wr_load_preflight, void *);
wr_runtime * wr_create(void);
// Install/clear only on the serial generation queue, outside wr_generate.
// The predicate is read at safe boundaries on that queue, never by llama workers.
typedef int (*wr_pause_predicate)(void *);
void wr_set_pause_callback(wr_runtime *, wr_pause_predicate, void *);
int wr_generate(wr_runtime *, const char * prompt, int max_tokens, char ** output);
// Request-scoped expiry is polled only at safe boundaries on the generation queue.
// Callback/data are borrowed only for this call; never retained on the runtime.
// Status 13 means expired authority; it neither sets nor resets wr_cancel.
typedef int (*wr_expiry_predicate)(void *);
int wr_generate_until(wr_runtime *, const char * prompt, int max_tokens, char ** output, wr_expiry_predicate, void *);
void wr_cancel(wr_runtime *);
void wr_unload(wr_runtime *);
void wr_destroy(wr_runtime *);
void wr_release(char *);
int wr_offloaded_layers(wr_runtime *);
int wr_total_layers(wr_runtime *);
int wr_execution_phase(wr_runtime *);
// Last completed generation's numeric bridge result; -1 before any generation.
int wr_generation_status(wr_runtime *);
int wr_dependencies_local(wr_runtime *, const char * directory);
#ifdef __cplusplus
}
#endif
