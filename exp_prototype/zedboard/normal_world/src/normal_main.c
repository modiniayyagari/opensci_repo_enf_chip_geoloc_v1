#include "normal_attestation_client.h"
#include "normal_uart_protocol.h"

#include "xil_printf.h"
#include "xstatus.h"

#include <string.h>

int main(void)
{
    char command[NORMAL_UART_COMMAND_MAX];
    u8 nonce[ATTESTATION_NONCE_BYTES];
    u8 verifier_id[ATTESTATION_VERIFIER_ID_BYTES];
    u32 request_id;
    u32 error_code;
    int secure_services_ready;

    NormalAttestationClearPending();
    xil_printf("[NORMAL] Secure ENF attestation service started\r\n");

    secure_services_ready = NormalAttestationInitialize();
    if (secure_services_ready != 0) {
        xil_printf("[NORMAL] Secure service ready\r\n");
    }

    xil_printf("HELLO ENF_LOCATION_ATTESTATION\r\n");
    xil_printf("IDLE\r\n");

    for (;;) {
        NormalProtocolParseResult get_result;

        if (NormalUartReadCommandLine(command, sizeof(command)) != XST_SUCCESS) {
            xil_printf("ERROR 0 BAD_COMMAND\r\n");
            NormalAttestationClearPending();
            xil_printf("IDLE\r\n");
            continue;
        }

        if (command[0] == '\0') {
            continue;
        }

        if (strcmp(command, "PING") == 0) {
            xil_printf("PONG\r\n");
            continue;
        }

        if (strncmp(command, "ATTEST", 6U) == 0) {
            request_id = 0U;
            if (NormalProtocolParseAttest(
                    command, &request_id, nonce, verifier_id) != XST_SUCCESS) {
                xil_printf("ERROR %u\r\n", (unsigned int)request_id);
                NormalAttestationClearPending();
                xil_printf("IDLE\r\n");
                continue;
            }

            /* ATTEST establishes the challenge; GET ENF starts capture. */
            NormalAttestationStoreChallenge(request_id, nonce, verifier_id);
            xil_printf("ACCEPTED %u\r\n", (unsigned int)request_id);
            continue;
        }

        if (strncmp(command, "GET", 3U) == 0) {
            request_id = 0U;
            get_result = NormalProtocolParseGetEnf(command, &request_id);

            if (get_result == NORMAL_PROTOCOL_UNSUPPORTED_MODE) {
                xil_printf("ERROR %u UNSUPPORTED_MODE\r\n",
                           (unsigned int)request_id);
                xil_printf("IDLE\r\n");
                continue;
            }

            if (get_result != NORMAL_PROTOCOL_VALID) {
                xil_printf("ERROR %u\r\n", (unsigned int)request_id);
                NormalAttestationClearPending();
                xil_printf("IDLE\r\n");
                continue;
            }

            if ((secure_services_ready == 0) ||
                !NormalAttestationRequestMatches(request_id)) {
                xil_printf("ERROR %u\r\n", (unsigned int)request_id);
                NormalAttestationClearPending();
                xil_printf("IDLE\r\n");
                continue;
            }

            /* Notify the verifier before the long Secure capture begins. */
            xil_printf("STARTED %u ENF\r\n", (unsigned int)request_id);

            if (NormalAttestationRunPending(&error_code) == XST_SUCCESS) {
                xil_printf("DONE %u ENF\r\n", (unsigned int)request_id);
            } else {
                xil_printf("[NORMAL] ERROR: request failed, code=%u\r\n",
                           (unsigned int)error_code);
                xil_printf("ERROR %u\r\n", (unsigned int)request_id);
            }

            NormalAttestationClearPending();
            xil_printf("IDLE\r\n");
            continue;
        }

        xil_printf("ERROR 0 BAD_COMMAND\r\n");
        NormalAttestationClearPending();
        xil_printf("IDLE\r\n");
    }
}
