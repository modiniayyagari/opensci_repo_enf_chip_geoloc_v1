#ifndef NORMAL_UART_PROTOCOL_H
#define NORMAL_UART_PROTOCOL_H
#include "attestation_smc_abi.h"
#define NORMAL_UART_COMMAND_MAX 96U
typedef enum { NORMAL_PROTOCOL_INVALID, NORMAL_PROTOCOL_VALID, NORMAL_PROTOCOL_UNSUPPORTED_MODE } NormalProtocolParseResult;
int NormalUartReadCommandLine(char *buffer, unsigned int capacity);
int NormalProtocolParseAttest(const char *line, u32 *request_id, u8 nonce[16], u8 verifier_id[16]);
NormalProtocolParseResult NormalProtocolParseGetEnf(const char *line, u32 *request_id);
void NormalProtocolSendAuthenticatedHexRecord(const char *name, u32 request_id, const u8 *bytes, unsigned int count);
#endif
