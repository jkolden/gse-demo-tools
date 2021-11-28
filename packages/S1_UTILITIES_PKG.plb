CREATE OR REPLACE PACKAGE BODY s1_utilities_pkg IS

    PROCEDURE create_blob (
        p_clob  IN   CLOB,
        p_blob  OUT  BLOB
    ) IS

        l_dest_offset  INTEGER := 1;
        l_src_offset   INTEGER := 1;
        l_warning      INTEGER;
        l_language     INTEGER := dbms_lob.default_lang_ctx;
    BEGIN
        dbms_lob.createtemporary(p_blob, false);

        dbms_lob.converttoblob(
            dest_lob => p_blob, 
            src_clob => p_clob, 
            amount => dbms_lob.lobmaxsize, 
            dest_offset => l_dest_offset,
            src_offset => l_src_offset,
            blob_csid => dbms_lob.default_csid, 
            lang_context => l_language, 
            warning => l_warning);
    
    DBMS_LOB.freetemporary(p_blob);

    END create_blob;

    PROCEDURE log_http_request (
        p_payload      IN  CLOB,
        p_response     IN  CLOB,
        p_status_code  IN  NUMBER,
        p_description  IN  VARCHAR2,
        p_instance     IN  VARCHAR2
    ) IS
        l_api_response  BLOB;
        l_api_payload   BLOB;
    BEGIN
        dbms_lob.createtemporary(l_api_payload, false);
        dbms_lob.createtemporary(l_api_response, false);
        create_blob(p_response, l_api_response);
        create_blob(p_payload, l_api_payload);
        INSERT INTO s1_http_requests (
            id,
            description,
            instance,
            payload,
            response,
            status_code,
            creation_date,
            created_by
        ) VALUES (
            s1_http_seq.NEXTVAL,
            p_description,
            p_instance,
            l_api_payload,
            l_api_response,
            p_status_code,
            sysdate,
            v('APP_USER')
        );

        dbms_lob.freetemporary(l_api_payload);
        dbms_lob.freetemporary(l_api_response);
    END log_http_request;

    PROCEDURE log_http_request (
        p_status_code  IN  NUMBER,
        p_description  IN  VARCHAR2,
        p_instance     IN  VARCHAR2
    ) IS
    BEGIN
        INSERT INTO s1_http_requests (
            id,
            description,
            instance,
            status_code,
            creation_date,
            created_by
        ) VALUES (
            s1_http_seq.NEXTVAL,
            p_description,
            p_instance,
            p_status_code,
            sysdate,
            v('APP_USER')
        );

    END log_http_request;

    FUNCTION get_user_initials RETURN VARCHAR2 AS
        l_user_initials VARCHAR(2 CHAR);
    BEGIN
        l_user_initials := upper(substr(v('APP_USER'), 1, 1)
                                 || substr(v('APP_USER'), instr(v('APP_USER'), '.') + 1, 1));

        RETURN l_user_initials;
    END get_user_initials;

-----------------------------------------------------------------------------------------
    -- generates a column-separated blob for a sql query passed in as the input parameter
-----------------------------------------------------------------------------------------

    FUNCTION get_csv (
        p_query IN VARCHAR2
    ) RETURN BLOB IS

    --http://marcsewtz.blogspot.com/2008/04/generating-csv-files-and-storing-them.html

        l_cursor         INTEGER;
        l_cursor_status  INTEGER;
        l_col_count      NUMBER;
        l_desc_tbl       sys.dbms_sql.desc_tab2;
        l_col_val        VARCHAR2(32767);
        l_row_num        NUMBER;
        l_report         BLOB;
        l_raw            RAW(32767);
    BEGIN
        l_row_num := 1;

-- open BLOB to store CSV file
        dbms_lob.createtemporary(l_report, false);
        dbms_lob.open(l_report, dbms_lob.lob_readwrite);

-- parse query
        l_cursor := dbms_sql.open_cursor;
        dbms_sql.parse(l_cursor, p_query, dbms_sql.native);
        dbms_sql.describe_columns2(l_cursor, l_col_count, l_desc_tbl);

-- define report columns
        FOR i IN 1..l_col_count LOOP
            dbms_sql.define_column(l_cursor, i, l_col_val, 32767);
        END LOOP;

        l_cursor_status := sys.dbms_sql.execute(l_cursor);

-- write result set to CSV file
        LOOP
            EXIT WHEN dbms_sql.fetch_rows(l_cursor) <= 0;
            FOR i IN 1..l_col_count LOOP
                dbms_sql.column_value(l_cursor, i, l_col_val);
                IF i = l_col_count THEN
                    l_col_val := ''
                                 || l_col_val
                                 || ''
                                 || chr(10); --end of line, insert line break
                ELSE
                    l_col_val := ''
                                 || l_col_val
                                 || ','; --insert comma and keep going
                END IF;

                l_raw := utl_raw.cast_to_raw(l_col_val);
                dbms_lob.writeappend(l_report, utl_raw.length(l_raw), l_raw);
            END LOOP;

            l_row_num := l_row_num + 1;
        END LOOP;

        dbms_sql.close_cursor(l_cursor);
        dbms_lob.close(l_report);

-- return CSV file
        RETURN l_report;
    END get_csv;

    FUNCTION parse_bip_response (
        p_clob IN CLOB
    ) RETURN CLOB IS
        l_xml       XMLTYPE;
        l_data      CLOB;
        l_xml_data  BLOB;
    BEGIN
   
   --make the clob an xmltype so we can parse as usual
        l_xml := xmltype.createxml(p_clob);
        SELECT
            data
        INTO l_data
        FROM
            XMLTABLE ( XMLNAMESPACES ( 'http://www.w3.org/2003/05/soap-envelope' AS "SOAP-ENV", 'http://xmlns.oracle.com/oxp/service/PublicReportService'
            AS "ns2" ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/ns2:runReportResponse/ns2:runReportReturn/ns2:reportBytes' PASSING l_xml
            COLUMNS data CLOB PATH '.' );

        RETURN l_data;
    END parse_bip_response;

    FUNCTION parse_ess_response (
        p_clob IN CLOB
    ) RETURN NUMBER IS
        l_start  NUMBER;
        l_end    NUMBER;
        l_clob   CLOB;
        l_xml    XMLTYPE;
        l_data   VARCHAR2(60);
    BEGIN
--get rid of stuff before and after the envelope that makes this response to not be valid xml:
        SELECT
            instr(p_clob, '<?xml version="1.0"')
        INTO l_start
        FROM
            dual;

        SELECT
            instr(p_clob, '</env:Envelope>')
        INTO l_end
        FROM
            dual;

        SELECT
            substr(p_clob, l_start,(l_end - l_start) + 15)
        INTO l_clob
        FROM
            dual;

    --make the cleaned up clob an xmltype so we can parse as usual

        l_xml := xmltype.createxml(l_clob);
        SELECT
            data
        INTO l_data
        FROM
            XMLTABLE ( XMLNAMESPACES ( 'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV", 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/'
            AS "ns0", 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/' AS "ns2" ),
            'SOAP-ENV:Envelope/SOAP-ENV:Body/ns0:submitESSJobRequestResponse/ns2:result' PASSING l_xml COLUMNS data CLOB PATH '.' );

        RETURN l_data;
    END parse_ess_response;

    FUNCTION parse_ess_status_response (
        p_xml IN XMLTYPE
    ) RETURN VARCHAR2 IS
        l_data VARCHAR2(60);
    BEGIN
        SELECT
            data
        INTO l_data
        FROM
            XMLTABLE ( XMLNAMESPACES ( 'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV", 'http://xmlns.oracle.com/scheduler'
            AS "ns0", 'http://xmlns.oracle.com/scheduler/types' AS "ns2" ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/ns0:getRequestStateResponse/state'
            PASSING p_xml COLUMNS data CLOB PATH '.' );

        RETURN l_data;
    END parse_ess_status_response;

    FUNCTION build_bulkdata_envelope (
        p_document_name      IN  VARCHAR2,
        p_filename           IN  VARCHAR2,
        p_data               IN  CLOB,
        p_account            IN  VARCHAR2,
        p_file_type          IN  VARCHAR2,
        p_user               IN  VARCHAR2,
        p_interface_details  IN  NUMBER
    ) RETURN CLOB IS
   
   /*
   This function is used to build the payload for the importBulkData SOAP service. 
   It returns an envelope (CLOB) that is used to consume the service. 
   
   Online documentation about the importBulkData service is here:
   https://docs.oracle.com/cloud/latest/financialscs_gs/OESWF/ERP_Integration_Service_ErpIntegrationService_svc_8.htm#importBulkData
   
   The return payload contains the ESS job id of the import process. 
   The return payload is parsed with the function s1_utilities_pkg.parse_bulkload_response.
   */
        l_envelope CLOB;
    BEGIN
        l_envelope := '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
   <soap:Body>
      <ns1:importBulkData xmlns:ns1="http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/">
         <ns1:document xmlns:ns2="http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/">
            <ns2:Content>'
                      || p_data
                      || '</ns2:Content>
            <ns2:FileName>'
                      || p_filename
                      || '.'
                      || p_file_type
                      || '</ns2:FileName>
            <ns2:ContentType>'
                      || p_file_type
                      || '</ns2:ContentType>
            <ns2:DocumentTitle>'
                      || p_filename
                      || '</ns2:DocumentTitle>
            <ns2:DocumentAuthor>'
                      || p_user
                      || '</ns2:DocumentAuthor>
            <ns2:DocumentSecurityGroup>FAFusionImportExport</ns2:DocumentSecurityGroup>
            <ns2:DocumentAccount>'
                      || p_account
                      || '</ns2:DocumentAccount>
            <ns2:DocumentName>'
                      || p_document_name
                      || '</ns2:DocumentName>
         </ns1:document>
         <ns1:notificationCode>#NULL</ns1:notificationCode>
         <ns1:callbackURL>#NULL</ns1:callbackURL>
         <ns1:jobOptions>ValidationOption = N, ImportOption = Y, PurgeOption = Y, ExtractFileType = ALL, InterfaceDetails = '
                      || p_interface_details
                      || '</ns1:jobOptions>
      </ns1:importBulkData>
   </soap:Body>
</soap:Envelope>';

        RETURN l_envelope;
    EXCEPTION
        WHEN OTHERS THEN
            record_error();
    END build_bulkdata_envelope;

    FUNCTION parse_bulkload_response (
        p_clob IN CLOB
    ) RETURN VARCHAR2 IS
        l_start  NUMBER;
        l_end    NUMBER;
        l_clob   CLOB;
        l_xml    XMLTYPE;
        l_data   VARCHAR2(60);
    BEGIN
    --get rid of stuff before and after the envelope that makes this response to not be valid xml:
        SELECT
            instr(p_clob, '<?xml version="1.0"')
        INTO l_start
        FROM
            dual;

        SELECT
            instr(p_clob, '</env:Envelope>')
        INTO l_end
        FROM
            dual;

        SELECT
            substr(p_clob, l_start,(l_end - l_start) + 15)
        INTO l_clob
        FROM
            dual;

    --make the cleaned up clob an xmltype so we can parse as usual

        l_xml := xmltype.createxml(l_clob);
        SELECT
            data
        INTO l_data
        FROM
            XMLTABLE ( XMLNAMESPACES ( 'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV", 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/'
            AS "ns0", 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/' AS "ns2" ),
            'SOAP-ENV:Envelope/SOAP-ENV:Body/ns0:importBulkDataResponse/ns2:result' PASSING l_xml COLUMNS data CLOB PATH '.' );

        RETURN l_data;
    EXCEPTION
        WHEN OTHERS THEN
            record_error();
    END parse_bulkload_response;

    FUNCTION parse_bulkload_error_response (
        p_clob IN CLOB
    ) RETURN VARCHAR2 IS
        l_clob   CLOB;
        l_start  NUMBER;
        l_end    NUMBER;
        l_data   VARCHAR2(1000);
        l_xml    XMLTYPE;
    BEGIN

    --get rid of stuff before and after the envelope that makes this response to not be valid xml:
        SELECT
            instr(p_clob, '<?xml version="1.0"')
        INTO l_start
        FROM
            dual;

        SELECT
            instr(p_clob, '</env:Envelope>')
        INTO l_end
        FROM
            dual;

        SELECT
            substr(p_clob, l_start,(l_end - l_start) + 15)
        INTO l_clob
        FROM
            dual;

        l_xml := xmltype.createxml(l_clob);
        SELECT
            substr(data, instr(data, '<'))
        INTO l_data
        FROM
            XMLTABLE ( XMLNAMESPACES ( 'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV" ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/SOAP-ENV:Fault'
            PASSING l_xml COLUMNS data PATH 'faultstring' );

        RETURN l_data;
    EXCEPTION
        WHEN OTHERS THEN
            record_error();
    END parse_bulkload_error_response;

    FUNCTION build_ess_envelope (
        p_ess_id IN NUMBER
    ) RETURN CLOB IS
        l_envelope CLOB;
    BEGIN
        l_envelope := '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:sch="http://xmlns.oracle.com/scheduler">
       <soapenv:Header xmlns:wsa="http://www.w3.org/2005/08/addressing"><wsa:Action>getRequestState</wsa:Action><wsa:MessageID>uuid:a1d68933-e327-42d8-8cd1-1cc4abd830d7</wsa:MessageID></soapenv:Header>
       <soapenv:Body>
          <sch:getRequestState>
             <sch:requestId>'
                      || p_ess_id
                      || '</sch:requestId>
          </sch:getRequestState>
       </soapenv:Body>
    </soapenv:Envelope>';
        RETURN l_envelope;
    END build_ess_envelope;

    FUNCTION build_ess_envelope (
        p_job_package     IN  VARCHAR2,
        p_job_definition  IN  VARCHAR2
    ) RETURN CLOB IS
        l_envelope CLOB;
    BEGIN
        l_envelope := '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:typ="http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/">
   <soapenv:Header/>
   <soapenv:Body>
      <typ:submitESSJobRequest>
         <typ:jobPackageName>'
                      || p_job_package
                      || '</typ:jobPackageName>
         <typ:jobDefinitionName>'
                      || p_job_definition
                      || '</typ:jobDefinitionName>
      </typ:submitESSJobRequest>
   </soapenv:Body>
</soapenv:Envelope>';
        RETURN l_envelope;
    END build_ess_envelope;

    PROCEDURE record_error IS
        PRAGMA autonomous_transaction;
        l_code  PLS_INTEGER := sqlcode;
        l_mesg  VARCHAR2(32767) := sqlerrm; 

   --taken from Steven Feuerstein's blog post on error handling: https://blogs.oracle.com/oraclemagazine/post/error-management
    BEGIN
        INSERT INTO error_log (
            error_code,
            error_message,
            backtrace,
            callstack,
            created_on,
            created_by
        ) VALUES (
            l_code,
            l_mesg,
            sys.dbms_utility.format_error_backtrace,
            sys.dbms_utility.format_call_stack,
            sysdate,
            v('APP_USER')
        );

        COMMIT;
    END;

END "S1_UTILITIES_PKG";
