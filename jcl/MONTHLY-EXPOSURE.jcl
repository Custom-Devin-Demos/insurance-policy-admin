//MONEXP   JOB (ACME,PAS),'MONTHLY EXPOSURE EXTRACT',
//         CLASS=A,MSGCLASS=X,MSGLEVEL=(1,1),
//         NOTIFY=&SYSUID,TIME=(2,)
//*******************************************************************
//* MONTHLY-EXPOSURE.JCL - Monthly Exposure Data for Actuarial
//* System:   Policy Administration System (PAS)
//* Schedule: 1st of month at 02:00 EST (CA-7 Job# PAS0200)
//* Author:   M. Kowalski
//* Date:     1999-03-01
//* Modified: 2008-07-01 - Added catastrophe zone data
//*           2015-01-15 - Added cyber exposure fields
//*           2026-11-20 - STEP020 now uses SFTP (SSH) with public-key
//*                        auth instead of plaintext FTP.
//*
//* Extracts monthly exposure data for actuarial analysis.
//* Output is consumed by SAS programs for loss reserving
//* and pricing models.
//*
//* OUTPUT: ACME.PAS.EXPOSURE.MONTHLY.Dyymmdd
//*******************************************************************
//*
//JOBLIB   DD DSN=ACME.PAS.LOADLIB,DISP=SHR
//         DD DSN=DB2.V12.SDSNLOAD,DISP=SHR
//*
//*-------------------------------------------------------------------
//* STEP010 - Generate exposure summary by line of business
//*-------------------------------------------------------------------
//STEP010  EXEC PGM=IKJEFT01,DYNAMNBR=20
//STEPLIB  DD DSN=DB2.V12.SDSNLOAD,DISP=SHR
//SYSTSPRT DD SYSOUT=*
//SYSPRINT DD SYSOUT=*
//EXPOUT   DD DSN=ACME.PAS.EXPOSURE.MONTHLY.D&LYYMMDD,
//         DISP=(NEW,CATLG,DELETE),
//         UNIT=SYSDA,SPACE=(CYL,(100,20),RLSE),
//         DCB=(RECFM=FB,LRECL=300,BLKSIZE=0)
//SYSTSIN  DD *
  DSN SYSTEM(DBPD)
  RUN PROGRAM(DSNTEP2) PLAN(DSNTEP12)
  END
/*
//SYSIN    DD *
  SELECT P.POLICY_TYPE,
         P.BRANCH_CODE,
         C.COVERAGE_TYPE,
         C.RATING_TERRITORY,
         C.CLASS_CODE,
         COUNT(*) AS POLICY_COUNT,
         SUM(C.COVERAGE_LIMIT) AS TOTAL_EXPOSURE,
         SUM(C.PREMIUM) AS TOTAL_PREMIUM,
         SUM(C.DEDUCTIBLE) AS TOTAL_DEDUCTIBLE
  FROM POLICIES P
  JOIN COVERAGES C
    ON P.POLICY_NUMBER = C.POLICY_NUMBER
  WHERE P.POLICY_STATUS = 'AC'
    AND C.STATUS = 'AC'
  GROUP BY P.POLICY_TYPE, P.BRANCH_CODE,
           C.COVERAGE_TYPE, C.RATING_TERRITORY,
           C.CLASS_CODE
  ORDER BY P.POLICY_TYPE, P.BRANCH_CODE;
/*
//*
//*-------------------------------------------------------------------
//* STEP020 - SFTP exposure extract to actuarial server
//*   Encrypted (SSH) transfer with public-key auth only; no password
//*   is sent or stored. The actuarial server host key must already
//*   be in the batch user's ~/.ssh/known_hosts
//*   (StrictHostKeyChecking=yes),
//*   and SFTP_KEY must be readable only by the batch user.
//*   Skipped unless STEP010 ended RC=0 so partial extracts are never
//*   sent.
//*-------------------------------------------------------------------
//STEP020  EXEC PGM=BPXBATCH,
//         COND=(0,NE,STEP010)
//STDOUT   DD SYSOUT=*
//STDERR   DD SYSOUT=*
//STDENV   DD *
SFTP_HOST=ACTUARIAL.ACME.LOCAL
SFTP_USER=ACMEFTP
SFTP_KEY=/u/acmebat/.ssh/id_pas_actuarial
/*
//STDPARM  DD *,SYMBOLS=EXECSYS
SH set -e;
 umask 077;
 W=/tmp/pas0200.$$;
 mkdir -m 700 "$W";
 trap 'rm -rf "$W"' EXIT;
 cp -T "//'ACME.PAS.EXPOSURE.MONTHLY.D&LYYMMDD'" "$W/exp.ebc";
 iconv -f IBM-1047 -t ISO8859-1 "$W/exp.ebc" > "$W/exp.csv";
 printf 'put %s %s\n'
 "$W/exp.csv" /actuarial/data/exposure_monthly.csv |
 sftp -b - -i "$SFTP_KEY"
 -o BatchMode=yes -o StrictHostKeyChecking=yes
 -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
 -o PreferredAuthentications=publickey
 "$SFTP_USER@$SFTP_HOST"
/*
//*
