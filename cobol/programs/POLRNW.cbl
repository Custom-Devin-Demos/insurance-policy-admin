       IDENTIFICATION DIVISION.
       PROGRAM-ID. POLRNW.
      ******************************************************************
      * POLRNW - Policy Renewal Program
      * CICS Transaction: PRWL
      * System:   Policy Administration System (PAS)
      * Author:   J. Henderson
      * Date:     1998-06-15
      * Modified: 2005-03-01 - Added auto-renewal logic
      *           2012-11-15 - Added rate increase cap (regulatory)
      *           2020-02-01 - COVID grace period extension
      *           2026-11-20 - Branch authorization via QUERY SECURITY
      *                        on FACILITY PAS.BRANCH.<branch-code>;
      *                        UPDATED_BY records signed-on user ID
      *
      * Processes policy renewals. Reads expiring policy, validates
      * renewal eligibility, applies rate changes, creates new term.
      * Batch mode supported via PREMBAT for mass renewals.
      ******************************************************************
       ENVIRONMENT DIVISION.
       CONFIGURATION SECTION.
       DATA DIVISION.
       WORKING-STORAGE SECTION.

       01  WS-PROGRAM-ID             PIC X(08) VALUE 'POLRNW'.
       01  WS-COMMAREA-LENGTH        PIC S9(04) COMP VALUE 256.
       01  WS-RESPONSE-CODE          PIC S9(08) COMP.
       01  WS-SQLCODE                PIC S9(09) COMP-5.
       01  WS-CURRENT-DATE           PIC 9(08).
       01  WS-NEW-EXPIRY-DATE        PIC 9(08).
       01  WS-ERROR-MSG              PIC X(79).
       01  WS-RATE-INCREASE-CAP      PIC S9(03)V99 COMP-3
           VALUE 15.00.
       01  WS-RATE-CHANGE-PCT        PIC S9(03)V99 COMP-3.
       01  WS-NEW-PREMIUM            PIC S9(09)V99 COMP-3.
       01  WS-OLD-PREMIUM            PIC S9(09)V99 COMP-3.
      * COVID grace period flag - added 2020
       01  WS-COVID-GRACE            PIC X(01) VALUE 'N'.
           88  COVID-GRACE-YES       VALUE 'Y'.
           88  COVID-GRACE-NO        VALUE 'N'.
      * Branch-level authorization (ESM FACILITY class profile)
       01  WS-USERID                 PIC X(08) VALUE SPACES.
       01  WS-BRANCH-IND             PIC S9(04) COMP VALUE 0.
       01  WS-SEC-UPDATE             PIC S9(08) COMP VALUE 0.
       01  WS-SEC-RESID-LEN          PIC S9(08) COMP VALUE 15.
       01  WS-SEC-RESID.
           05  FILLER                PIC X(11) VALUE 'PAS.BRANCH.'.
           05  WS-SEC-RESID-BRANCH   PIC X(04) VALUE SPACES.

       COPY POLICY-RECORD.
       COPY COVERAGE-RECORD.
       COPY PREMIUM-RECORD.

           EXEC SQL INCLUDE SQLCA END-EXEC.

       LINKAGE SECTION.
       01  DFHCOMMAREA               PIC X(256).

       PROCEDURE DIVISION.
       0000-MAIN-LOGIC.
           PERFORM 1000-INITIALIZE
           PERFORM 2000-READ-EXISTING-POLICY
           IF WS-ERROR-MSG = SPACES
               PERFORM 2500-CHECK-AUTHORIZATION
           END-IF
           IF WS-ERROR-MSG = SPACES
               PERFORM 3000-CHECK-RENEWAL-ELIGIBILITY
           END-IF
           IF WS-ERROR-MSG = SPACES
               PERFORM 4000-CALCULATE-NEW-PREMIUM
               PERFORM 5000-APPLY-RATE-CAP
               PERFORM 6000-CREATE-RENEWAL-TERM
               IF WS-ERROR-MSG = SPACES
                   PERFORM 7000-UPDATE-COVERAGES
                   PERFORM 8000-SEND-CONFIRMATION
               END-IF
           ELSE
               PERFORM 9000-SEND-ERROR
           END-IF
           PERFORM 9999-RETURN
           .

       1000-INITIALIZE.
           MOVE SPACES TO WS-ERROR-MSG
           EXEC CICS ASKTIME
               ABSTIME(WS-CURRENT-DATE)
           END-EXEC
           EXEC CICS FORMATTIME
               ABSTIME(WS-CURRENT-DATE)
               YYYYMMDD(WS-CURRENT-DATE)
           END-EXEC
           EXEC CICS ASSIGN
               USERID(WS-USERID)
               RESP(WS-RESPONSE-CODE)
           END-EXEC
           IF WS-RESPONSE-CODE NOT = DFHRESP(NORMAL)
              OR WS-USERID = SPACES
               MOVE 'UNABLE TO DETERMINE SIGNED-ON USER' TO WS-ERROR-MSG
           END-IF
           .

       2000-READ-EXISTING-POLICY.
           IF WS-ERROR-MSG NOT = SPACES
               GO TO 2000-EXIT
           END-IF
           EXEC CICS RECEIVE
               MAP('POLRMAP')
               MAPSET('POLRMAPS')
               INTO(POLICY-RECORD)
               RESP(WS-RESPONSE-CODE)
           END-EXEC
           IF WS-RESPONSE-CODE NOT = DFHRESP(NORMAL)
               MOVE 'ERROR RECEIVING RENEWAL DATA' TO WS-ERROR-MSG
               GO TO 2000-EXIT
           END-IF
           EXEC SQL
               SELECT POLICY_NUMBER, POLICY_TYPE, POLICY_STATUS,
                      TOTAL_PREMIUM, EXPIRY_DATE, RENEWAL_COUNT,
                      UW_STATUS, BRANCH_CODE
               INTO :POLICY-NUMBER, :POLICY-TYPE, :POLICY-STATUS,
                    :POLICY-TOTAL-PREMIUM, :POLICY-EXPIRY-DATE,
                    :POLICY-RENEWAL-COUNT, :POLICY-UW-STATUS,
                    :POLICY-BRANCH-CODE :WS-BRANCH-IND
               FROM POLICIES
               WHERE POLICY_NUMBER = :POLICY-NUMBER
           END-EXEC
           IF SQLCODE NOT = 0
               MOVE 'POLICY NOT FOUND FOR RENEWAL' TO WS-ERROR-MSG
           END-IF
           .
       2000-EXIT.
           EXIT.

       2500-CHECK-AUTHORIZATION.
      *    Signed-on user must have UPDATE access to the policy's
      *    branch profile. Missing branch or ESM error denies.
           IF WS-BRANCH-IND < 0 OR POLICY-BRANCH-CODE = SPACES
               MOVE 'NOT AUTHORIZED TO RENEW THIS POLICY'
                   TO WS-ERROR-MSG
               GO TO 2500-EXIT
           END-IF
           MOVE POLICY-BRANCH-CODE TO WS-SEC-RESID-BRANCH
           EXEC CICS QUERY SECURITY
               RESCLASS('FACILITY')
               RESID(WS-SEC-RESID)
               RESIDLENGTH(WS-SEC-RESID-LEN)
               UPDATE(WS-SEC-UPDATE)
               RESP(WS-RESPONSE-CODE)
           END-EXEC
           IF WS-RESPONSE-CODE NOT = DFHRESP(NORMAL)
              OR WS-SEC-UPDATE NOT = DFHVALUE(UPDATABLE)
               MOVE 'NOT AUTHORIZED TO RENEW THIS POLICY'
                   TO WS-ERROR-MSG
           END-IF
           .
       2500-EXIT.
           EXIT.

       3000-CHECK-RENEWAL-ELIGIBILITY.
           IF NOT POL-STAT-ACTIVE AND NOT POL-STAT-EXPIRED
               MOVE 'POLICY NOT ELIGIBLE FOR RENEWAL' TO WS-ERROR-MSG
           END-IF
      *    Check for outstanding claims
           EXEC SQL
               SELECT COUNT(*)
               INTO :WS-SQLCODE
               FROM ACMEINS.CLAIMS
               WHERE POLICY_NUMBER = :POLICY-NUMBER
                 AND CLAIM_STATUS = 'OPEN'
           END-EXEC
      *    TODO: Business wants to block renewal if >3 open claims
      *    but this was never fully implemented - JH 2005
           .

       4000-CALCULATE-NEW-PREMIUM.
           MOVE POLICY-TOTAL-PREMIUM TO WS-OLD-PREMIUM
      *    Apply standard rate increase (hardcoded - should be
      *    table-driven but actuarial never provided the table)
           COMPUTE WS-NEW-PREMIUM =
               WS-OLD-PREMIUM * 1.05
           COMPUTE WS-RATE-CHANGE-PCT =
               ((WS-NEW-PREMIUM - WS-OLD-PREMIUM)
                / WS-OLD-PREMIUM) * 100
           .

       5000-APPLY-RATE-CAP.
      *    Regulatory rate increase cap - varies by state
      *    Using flat 15% cap for now (TODO: state-specific caps)
           IF WS-RATE-CHANGE-PCT > WS-RATE-INCREASE-CAP
               COMPUTE WS-NEW-PREMIUM =
                   WS-OLD-PREMIUM * (1 + WS-RATE-INCREASE-CAP / 100)
           END-IF
           MOVE WS-NEW-PREMIUM TO POLICY-TOTAL-PREMIUM
           .

       6000-CREATE-RENEWAL-TERM.
           ADD 1 TO POLICY-RENEWAL-COUNT
           MOVE POLICY-EXPIRY-DATE TO POLICY-EFFECTIVE-DATE
      *    Add 1 year to effective date for new expiry
      *    Simple arithmetic - does not handle leap years properly
           ADD 10000 TO POLICY-EXPIRY-DATE
                        GIVING WS-NEW-EXPIRY-DATE
           MOVE WS-NEW-EXPIRY-DATE TO POLICY-EXPIRY-DATE
           MOVE 'AC' TO POLICY-STATUS
           MOVE 'PN' TO POLICY-UW-STATUS

           EXEC SQL
               UPDATE POLICIES
               SET POLICY_STATUS = :POLICY-STATUS,
                   EFFECTIVE_DATE = :POLICY-EFFECTIVE-DATE,
                   EXPIRY_DATE = :POLICY-EXPIRY-DATE,
                   TOTAL_PREMIUM = :POLICY-TOTAL-PREMIUM,
                   RENEWAL_COUNT = :POLICY-RENEWAL-COUNT,
                   UW_STATUS = :POLICY-UW-STATUS,
                   LAST_UPDATED = CURRENT TIMESTAMP,
                   UPDATED_BY = :WS-USERID
               WHERE POLICY_NUMBER = :POLICY-NUMBER
                 AND BRANCH_CODE = :POLICY-BRANCH-CODE
           END-EXEC
           IF SQLCODE NOT = 0 OR SQLERRD(3) NOT = 1
               MOVE 'DB2 ERROR UPDATING RENEWAL' TO WS-ERROR-MSG
               EXEC CICS SYNCPOINT ROLLBACK END-EXEC
               PERFORM 9000-SEND-ERROR
           END-IF
           .

       7000-UPDATE-COVERAGES.
      *    Extend coverage dates to match new policy term
           EXEC SQL
               UPDATE COVERAGES
               SET EFFECTIVE_DATE = :POLICY-EFFECTIVE-DATE,
                   EXPIRY_DATE = :POLICY-EXPIRY-DATE
               WHERE POLICY_NUMBER = :POLICY-NUMBER
                 AND STATUS = 'AC'
           END-EXEC
           .

       8000-SEND-CONFIRMATION.
           EXEC CICS SEND
               MAP('POLRCONF')
               MAPSET('POLRMAPS')
               FROM(POLICY-RECORD)
               ERASE
           END-EXEC
           .

       9000-SEND-ERROR.
           EXEC CICS SEND TEXT
               FROM(WS-ERROR-MSG)
               LENGTH(79)
               ERASE
           END-EXEC
           .

       9999-RETURN.
           EXEC CICS RETURN
               TRANSID('PRWL')
               COMMAREA(DFHCOMMAREA)
               LENGTH(WS-COMMAREA-LENGTH)
           END-EXEC
           .
