#ifndef FLCLASH_CORE_H
#define FLCLASH_CORE_H

#include <stdint.h>

char *flclash_core_invoke(const char *request);
char *flclash_core_event(void);
char *flclash_core_start(const char *ipv4, const char *ipv6, int32_t mtu);
void flclash_core_stop(void);
void flclash_core_network_changed(void);
void flclash_core_write_packets(const uint8_t *packets, int32_t length);
int32_t flclash_core_read_packets(uint8_t *packets, int32_t capacity);

#endif
