//POLEXT   JOB (ACME,PAS),'DAILY POLICY EXTRACT',
//         CLASS=A,MSGCLASS=X,MSGLEVEL=(1,1),
//         NOTIFY=&SYSUID,TIME=(,30)
//*******************************************************************
//* DAILY-EXTRACT.JCL - Nightly Policy Data Extract to Claims
//* System:   Policy Administration System (PAS)
//* Schedule: Daily at 23:00 EST (CA-7 Job# PAS0100)
//* Author:   J. Henderson
//* Date:     1998-09-01
//* Modified: 2005-03-15 - Added Claims system extract
//*           2012-11-01 - Added encryption step (regulatory)
//*           2026-11-20 - The 2012 encryption step was never in this
//*                        job; extracts went out over plaintext FTP.
//*                        STEP030 now uses SFTP (SSH) with public-key
//*                        auth and runs only if all prior steps RC=0.
//*
//* Extracts active policy data from DB2 and creates flat files
//* for consumption by Claims Engine (VB6 batch import) and
//* Broker Portal (linked server refresh).
//*
//* OUTPUT FILES:
//*   ACME.PAS.EXTRACT.POLICY.DAILY    - Policy header extract
//*   ACME.PAS.EXTRACT.COVERAGE.DAILY  - Coverage detail extract
//*   ACME.PAS.EXTRACT.CUSTOMER.DAILY  - Customer data extract
//*
//* DEPENDENCIES: DB2 subsystem DBPD must be active
//*******************************************************************
//*
//JOBLIB   DD DSN=ACME.PAS.LOADLIB,DISP=SHR
//         DD DSN=DB2.V12.SDSNLOAD,DISP=SHR
//*
//*-------------------------------------------------------------------
//* STEP010 - Extract policy headers from DB2
//*-------------------------------------------------------------------
//STEP010  EXEC PGM=IKJEFT01,DYNAMNBR=20
//STEPLIB  DD DSN=DB2.V12.SDSNLOAD,DISP=SHR
//SYSTSPRT DD SYSOUT=*
//SYSPRINT DD SYSOUT=*
//SYSUDUMP DD SYSOUT=*
//POLOUT   DD DSN=ACME.PAS.EXTRACT.POLICY.DAILY,
//         DISP=(NEW,CATLG,DELETE),
//         UNIT=SYSDA,SPACE=(CYL,(50,10),RLSE),
//         DCB=(RECFM=FB,LRECL=200,BLKSIZE=0)
//SYSTSIN  DD *
  DSN SYSTEM(DBPD)
  RUN PROGRAM(DSNTEP2) PLAN(DSNTEP12) -
      LIB('ACME.PAS.LOADLIB')
  END
/*
//SYSIN    DD *
  SELECT POLICY_NUMBER, POLICY_TYPE, POLICY_STATUS,
         EFFECTIVE_DATE, EXPIRY_DATE,
         POLICYHOLDER_ID, AGENT_CODE, BRANCH_CODE,
         TOTAL_PREMIUM, DEDUCTIBLE, COVERAGE_LIMIT,
         UW_STATUS, RISK_SCORE
  FROM POLICIES
  WHERE POLICY_STATUS IN ('AC', 'PN')
    AND LAST_UPDATED >= CURRENT DATE - 1 DAY
  ORDER BY POLICY_NUMBER;
/*
//*
//*-------------------------------------------------------------------
//* STEP020 - Extract coverage details
//*-------------------------------------------------------------------
//STEP020  EXEC PGM=IKJEFT01,DYNAMNBR=20,
//         COND=(4,LT,STEP010)
//STEPLIB  DD DSN=DB2.V12.SDSNLOAD,DISP=SHR
//SYSTSPRT DD SYSOUT=*
//COVOUT   DD DSN=ACME.PAS.EXTRACT.COVERAGE.DAILY,
//         DISP=(NEW,CATLG,DELETE),
//         UNIT=SYSDA,SPACE=(CYL,(30,10),RLSE),
//         DCB=(RECFM=FB,LRECL=150,BLKSIZE=0)
//SYSTSIN  DD *
  DSN SYSTEM(DBPD)
  RUN PROGRAM(DSNTEP2) PLAN(DSNTEP12)
  END
/*
//SYSIN    DD *
  SELECT POLICY_NUMBER, SEQUENCE_NUM, COVERAGE_TYPE,
         DESCRIPTION, COVERAGE_LIMIT, DEDUCTIBLE,
         PREMIUM, EFFECTIVE_DATE, EXPIRY_DATE, STATUS
  FROM COVERAGES
  WHERE STATUS = 'AC'
  ORDER BY POLICY_NUMBER, SEQUENCE_NUM;
/*
//*
//*-------------------------------------------------------------------
//* STEP030 - SFTP extract files to Claims server
//*   Encrypted (SSH) transfer with public-key auth only; no password
//*   is sent or stored. The claims server host key must already be in
//*   the batch user's ~/.ssh/known_hosts (StrictHostKeyChecking=yes),
//*   and SFTP_KEY must be readable only by the batch user.
//*   Skipped unless every prior step ended RC=0 so partial extracts
//*   are never sent.
//*-------------------------------------------------------------------
//STEP030  EXEC PGM=BPXBATCH,
//         COND=(0,NE)
//STDOUT   DD SYSOUT=*
//STDERR   DD SYSOUT=*
//STDENV   DD *
SFTP_HOST=CLAIMSRV.ACME.LOCAL
SFTP_USER=ACMEFTP
SFTP_KEY=/u/acmebat/.ssh/id_pas_claims
/*
//STDPARM  DD *
SH set -e;
 umask 077;
 W=/tmp/pas0100.$$;
 mkdir -m 700 "$W";
 trap 'rm -rf "$W"' EXIT;
 cp -T "//'ACME.PAS.EXTRACT.POLICY.DAILY'" "$W/pol.ebc";
 cp -T "//'ACME.PAS.EXTRACT.COVERAGE.DAILY'" "$W/cov.ebc";
 iconv -f IBM-1047 -t ISO8859-1 "$W/pol.ebc" > "$W/pol.dat";
 iconv -f IBM-1047 -t ISO8859-1 "$W/cov.ebc" > "$W/cov.dat";
 printf 'put %s %s\nput %s %s\n'
 "$W/pol.dat" /claims/import/policy_extract.dat
 "$W/cov.dat" /claims/import/coverage_extract.dat |
 sftp -b - -i "$SFTP_KEY"
 -o BatchMode=yes -o StrictHostKeyChecking=yes
 -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
 -o PreferredAuthentications=publickey
 "$SFTP_USER@$SFTP_HOST"
/*
//*
