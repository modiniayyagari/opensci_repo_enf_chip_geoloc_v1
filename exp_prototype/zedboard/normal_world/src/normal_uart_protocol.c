#include "normal_uart_protocol.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xuartps_hw.h"
#include "xil_printf.h"
#include <string.h>

#if defined(XPAR_XUARTPS_0_BASEADDR)
#define NORMAL_UART_BASE_ADDRESS XPAR_XUARTPS_0_BASEADDR
#elif defined(STDOUT_BASEADDRESS)
#define NORMAL_UART_BASE_ADDRESS STDOUT_BASEADDRESS
#else
#error "No Normal World UART base address"
#endif

static u8 ReadByteBlocking(void)
{
    while (!XUartPs_IsReceiveData(NORMAL_UART_BASE_ADDRESS)) {
        /* Commands are serviced synchronously. */
    }
    return (u8)XUartPs_ReadReg(NORMAL_UART_BASE_ADDRESS,
                               XUARTPS_FIFO_OFFSET);
}

int NormalUartReadCommandLine(char *buffer, unsigned int capacity)
{
    unsigned int length = 0U;
    int overflowed = 0;

    if ((buffer == NULL) || (capacity < 2U)) {
        return XST_FAILURE;
    }

    for (;;) {
        u8 byte = ReadByteBlocking();

        if ((byte == (u8)'\r') || (byte == (u8)'\n')) {
            if (overflowed != 0) {
                buffer[0] = '\0';
                return XST_FAILURE;
            }
            buffer[length] = '\0';
            return XST_SUCCESS;
        }
        if (overflowed != 0) {
            continue;
        }
        if ((length + 1U) >= capacity) {
            overflowed = 1;
            continue;
        }
        buffer[length++] = (char)byte;
    }
}

static const char *SkipSpaces(const char *text)
{
    while ((text != NULL) && ((*text == ' ') || (*text == '\t') ||
           (*text == '\r') || (*text == '\n'))) {
        text++;
    }
    return text;
}

static int ReadToken(const char **text, char *token, u32 capacity)
{
    const char *cursor;
    u32 length = 0U;
    int truncated = 0;

    if ((text == NULL) || (*text == NULL) || (token == NULL) ||
        (capacity == 0U)) {
        return 0;
    }

    cursor = SkipSpaces(*text);
    while ((*cursor != '\0') && (*cursor != ' ') && (*cursor != '\t') &&
           (*cursor != '\r') && (*cursor != '\n')) {
        if ((length + 1U) < capacity) {
            token[length++] = *cursor;
        } else {
            truncated = 1;
        }
        cursor++;
    }
    token[length] = '\0';
    *text = SkipSpaces(cursor);
    return ((length != 0U) && (truncated == 0)) ? 1 : 0;
}

static int ParseDecimal(const char *text, u32 *value)
{
    u32 parsed = 0U;

    if ((text == NULL) || (value == NULL) || (*text == '\0')) {
        return 0;
    }
    while (*text != '\0') {
        u32 digit;

        if ((*text < '0') || (*text > '9')) {
            return 0;
        }
        digit = (u32)(*text - '0');
        if ((parsed > 429496729U) ||
            ((parsed == 429496729U) && (digit > 5U))) {
            return 0;
        }
        parsed = (parsed * 10U) + digit;
        text++;
    }
    *value = parsed;
    return 1;
}

static int HexNibble(char character, u8 *value)
{
    if ((character >= '0') && (character <= '9')) {
        *value = (u8)(character - '0');
    } else if ((character >= 'a') && (character <= 'f')) {
        *value = (u8)(character - 'a' + 10);
    } else if ((character >= 'A') && (character <= 'F')) {
        *value = (u8)(character - 'A' + 10);
    } else {
        return 0;
    }
    return 1;
}

static int ParseNonce(const char *hex, u8 nonce[ATTESTATION_NONCE_BYTES])
{
    u32 index;

    for (index = 0U; index < ATTESTATION_NONCE_BYTES; index++) {
        u8 high;
        u8 low;

        if (!HexNibble(hex[index * 2U], &high) ||
            !HexNibble(hex[(index * 2U) + 1U], &low)) {
            return 0;
        }
        nonce[index] = (u8)((high << 4) | low);
    }
    return (hex[ATTESTATION_NONCE_BYTES * 2U] == '\0') ? 1 : 0;
}

int NormalProtocolParseAttest(const char *line, u32 *request_id,
    u8 nonce[ATTESTATION_NONCE_BYTES],
    u8 verifier_id[ATTESTATION_VERIFIER_ID_BYTES])
{
    const char *cursor = line;
    char command[8], request[16], nonce_hex[33], verifier[64];
    u8 parsed_nonce[ATTESTATION_NONCE_BYTES];
    u32 parsed_request;
    u32 index;

    if ((line == NULL) || (request_id == NULL) || (nonce == NULL) ||
        (verifier_id == NULL) ||
        !ReadToken(&cursor, command, sizeof(command)) ||
        (strcmp(command, "ATTEST") != 0) ||
        !ReadToken(&cursor, request, sizeof(request)) ||
        !ParseDecimal(request, &parsed_request) ||
        !ReadToken(&cursor, nonce_hex, sizeof(nonce_hex)) ||
        !ParseNonce(nonce_hex, parsed_nonce) ||
        !ReadToken(&cursor, verifier, sizeof(verifier)) ||
        (*cursor != '\0')) {
        return XST_FAILURE;
    }

    *request_id = parsed_request;
    memcpy(nonce, parsed_nonce, ATTESTATION_NONCE_BYTES);
    memset(verifier_id, 0, ATTESTATION_VERIFIER_ID_BYTES);
    for (index = 0U;
         (index < (ATTESTATION_VERIFIER_ID_BYTES - 1U)) &&
         (verifier[index] != '\0');
         index++) {
        verifier_id[index] = (u8)verifier[index];
    }
    return XST_SUCCESS;
}

NormalProtocolParseResult NormalProtocolParseGetEnf(
    const char *line, u32 *request_id)
{
    const char *cursor = line;
    char command[8], request[16], mode[8];

    if ((line == NULL) || (request_id == NULL) ||
        !ReadToken(&cursor, command, sizeof(command)) ||
        (strcmp(command, "GET") != 0) ||
        !ReadToken(&cursor, request, sizeof(request)) ||
        !ParseDecimal(request, request_id) ||
        !ReadToken(&cursor, mode, sizeof(mode)) || (*cursor != '\0')) {
        return NORMAL_PROTOCOL_INVALID;
    }
    if (strcmp(mode, "ENF") != 0) {
        return NORMAL_PROTOCOL_UNSUPPORTED_MODE;
    }
    return NORMAL_PROTOCOL_VALID;
}

void NormalProtocolSendAuthenticatedHexRecord(const char *record_name,
    u32 request_id, const u8 *bytes, unsigned int byte_count)
{
    static const char LowerHex[] = "0123456789abcdef";
    unsigned int index;

    xil_printf("%s %u ", record_name, (unsigned int)request_id);
    for (index = 0U; index < byte_count; index++) {
        xil_printf("%c%c",
            LowerHex[(bytes[index] >> 4) & 0x0FU],
            LowerHex[bytes[index] & 0x0FU]);
    }
    xil_printf("\r\n");
}

