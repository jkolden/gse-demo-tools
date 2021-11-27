create or replace package body s1_utilities_pkg is

procedure create_blob(p_clob IN clob, p_blob OUT blob)
    is
    l_dest_offset    integer := 1;
    l_src_offset     integer := 1;
    l_warning        integer;
    l_language       integer := DBMS_LOB.DEFAULT_LANG_CTX;
     
    begin
     DBMS_LOB.createtemporary(p_blob, FALSE);
     
     DBMS_LOB.convertToBlob(
                          dest_lob     => p_blob,
                          src_clob     => p_clob,
                          amount       => DBMS_LOB.LOBMAXSIZE,
                          dest_offset  => l_dest_offset,
                          src_offset   => l_src_offset,
                          blob_csid    => DBMS_LOB.DEFAULT_CSID,
                          lang_context => l_language,
                          warning      => l_warning
    );
    
    --DBMS_LOB.freetemporary(p_blob);
    
    end create_blob;

procedure log_http_request (
    p_payload      IN  clob, 
    p_response     IN  clob, 
    p_status_code  IN  number, 
    p_description  IN  varchar2,
    p_instance     IN  varchar2
    )
    
    is
    l_api_response   blob;
    l_api_payload    blob;
        
    begin
    DBMS_LOB.createtemporary(l_api_payload, FALSE);
    DBMS_LOB.createtemporary(l_api_response, FALSE);
    
    create_blob(p_response,l_api_response );
    create_blob(p_payload, l_api_payload );
       
    insert into s1_http_requests(
        id,
        description,
        instance,
        payload,
        response,
        status_code,
        creation_date,
        created_by)
    values (
        s1_http_seq.nextval,
        p_description,
        p_instance,
        l_api_payload,
        l_api_response,
        p_status_code,
        sysdate,
        V('APP_USER')        
    );
    
    DBMS_LOB.freetemporary(l_api_payload);
    DBMS_LOB.freetemporary(l_api_response);
    
    end log_http_request;
    
procedure log_http_request (
    p_status_code  IN  number, 
    p_description  IN  varchar2,
    p_instance     IN  varchar2
    )
    
    is
        
    begin
       
    insert into s1_http_requests(
        id,
        description,
        instance,
        status_code,
        creation_date,
        created_by)
    values (
        s1_http_seq.nextval,
        p_description,
        p_instance,
        p_status_code,
        sysdate,
        V('APP_USER')        
    );
    
    end log_http_request;

function get_user_initials
    return varchar2
  as
    l_user_initials varchar(2 char);
  begin
    l_user_initials := upper(SUBSTR(V('APP_USER'), 1, 1)||SUBSTR(V('APP_USER'), instr(V('APP_USER'),'.') + 1, 1));
    return l_user_initials;
  end get_user_initials;

-----------------------------------------------------------------------------------------
    -- generates a column-separated blob for a sql query passed in as the input parameter
-----------------------------------------------------------------------------------------
function get_csv(p_query in varchar2) 
 return blob

is
    l_cursor integer;
    l_cursor_status integer;
    l_col_count number;
    l_desc_tbl sys.dbms_sql.desc_tab2;
    l_col_val varchar2(32767);
    l_row_num number;

    l_report blob;
    l_raw raw(32767);
    begin
    l_row_num := 1;

-- open BLOB to store CSV file
    dbms_lob.createtemporary( l_report, FALSE );
    dbms_lob.open( l_report, dbms_lob.lob_readwrite );

-- parse query
    l_cursor := dbms_sql.open_cursor;
    dbms_sql.parse(l_cursor, p_query, dbms_sql.native);
    dbms_sql.describe_columns2(l_cursor, l_col_count, l_desc_tbl );

-- define report columns
for i in 1 .. l_col_count 
    loop
        dbms_sql.define_column(l_cursor, i, l_col_val, 32767 );
    end loop;


    l_cursor_status := sys.dbms_sql.execute(l_cursor);

-- write result set to CSV file
loop
exit when dbms_sql.fetch_rows(l_cursor) <= 0;
for i in 1 .. l_col_count 
loop
    dbms_sql.column_value(l_cursor, i, l_col_val);
    if i = l_col_count then
        l_col_val := ''||l_col_val||''||chr(10); --end of line, insert line break
        else
        l_col_val := ''||l_col_val||','; --insert comma and keep going
    end if;
    l_raw := utl_raw.cast_to_raw( l_col_val );
    dbms_lob.writeappend( l_report, utl_raw.length( l_raw ), l_raw );

end loop;

    l_row_num := l_row_num + 1;

end loop;

    dbms_sql.close_cursor(l_cursor);
    dbms_lob.close( l_report );

-- return CSV file
return l_report;

end get_csv;

function parse_bip_response(p_clob in clob)
   return clob
   
   is
   
   l_xml XMLTYPE;
   l_data CLOB;
   l_xml_data BLOB;
   
   begin
   
   --make the clob an xmltype so we can parse as usual
    l_xml := XMLTYPE.createXML(p_clob);

    select data into l_data
       from 
       XMLTable(  
             XMLNamespaces(  
                 'http://www.w3.org/2003/05/soap-envelope'  AS "SOAP-ENV"                  
                ,'http://xmlns.oracle.com/oxp/service/PublicReportService' AS  "ns2" 
                
              ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/ns2:runReportResponse/ns2:runReportReturn/ns2:reportBytes' 
              passing   l_xml 
              columns data clob path '.'  
           ) ;
                      
           return l_data;
   
end parse_bip_response;

function parse_ess_response(p_clob IN clob)
  return number

is

  l_start number;
  l_end number;
  l_clob clob;
  l_xml xmltype;
  l_data varchar2(60);


begin
--get rid of stuff before and after the envelope that makes this response to not be valid xml:
    select instr(p_clob, '<?xml version="1.0"') into l_start from DUAL;
    select instr(p_clob, '</env:Envelope>') into l_end from DUAL;
    select substr(p_clob, l_start, (l_end - l_start) +15 ) into l_clob from DUAL;

    --make the cleaned up clob an xmltype so we can parse as usual
    l_xml := XMLTYPE.createXML(l_clob);

    SELECT data  into l_data
       FROM 
       XMLTable(  
             XMLNamespaces(  
               'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV"  
                ,'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/' AS  "ns0" 
                , 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/' AS "ns2"
                
              ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/ns0:submitESSJobRequestResponse/ns2:result' 
              passing   l_xml 
              columns data clob path '.'  
           ) ;
           
    return l_data;

end parse_ess_response;

function parse_ess_status_response(p_xml IN xmltype)
    return varchar2 

    is

    l_data varchar2(60);

    begin
    
    SELECT data  into l_data
       FROM 
       XMLTable(  
             XMLNamespaces(  
               'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV"  
                ,'http://xmlns.oracle.com/scheduler' AS  "ns0" 
                , 'http://xmlns.oracle.com/scheduler/types' AS "ns2"
                
              ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/ns0:getRequestStateResponse/state' 
              passing   p_xml 
              columns data clob path '.'  
           );
           
           return l_data;
           
end parse_ess_status_response;

function build_bulkdata_envelope(p_document_name IN varchar2, p_filename IN varchar2, p_data IN clob, p_account IN varchar2, p_file_type IN varchar2 , p_user IN varchar2, p_interface_details IN number)
   return clob
 is
   
   /*
   This function is used to build the payload for the importBulkData SOAP service. 
   It returns an envelope (CLOB) that is used to consume the service. 
   
   Online documentation about the importBulkData service is here:
   https://docs.oracle.com/cloud/latest/financialscs_gs/OESWF/ERP_Integration_Service_ErpIntegrationService_svc_8.htm#importBulkData
   
   The return payload contains the ESS job id of the import process. 
   The return payload is parsed with the function s1_utilities_pkg.parse_bulkload_response.
   */
   
   l_envelope clob;
   
   begin

l_envelope := '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
   <soap:Body>
      <ns1:importBulkData xmlns:ns1="http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/">
         <ns1:document xmlns:ns2="http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/">
            <ns2:Content>'||p_data||'</ns2:Content>
            <ns2:FileName>'||p_filename||'.'||p_file_type||'</ns2:FileName>
            <ns2:ContentType>'||p_file_type||'</ns2:ContentType>
            <ns2:DocumentTitle>'||p_filename||'</ns2:DocumentTitle>
            <ns2:DocumentAuthor>'||p_user||'</ns2:DocumentAuthor>
            <ns2:DocumentSecurityGroup>FAFusionImportExport</ns2:DocumentSecurityGroup>
            <ns2:DocumentAccount>'||p_account||'</ns2:DocumentAccount>
            <ns2:DocumentName>'||p_document_name||'</ns2:DocumentName>
         </ns1:document>
         <ns1:notificationCode>#NULL</ns1:notificationCode>
         <ns1:callbackURL>#NULL</ns1:callbackURL>
         <ns1:jobOptions>ValidationOption = N, ImportOption = Y, PurgeOption = Y, ExtractFileType = ALL, InterfaceDetails = '||p_interface_details||'</ns1:jobOptions>
      </ns1:importBulkData>
   </soap:Body>
</soap:Envelope>';

RETURN l_envelope;

exception when others then
           record_error();

end build_bulkdata_envelope;

function parse_bulkload_response (p_clob IN clob)
   return varchar2
      
   is
    l_start number;
    l_end number;
    l_clob clob;
    l_xml xmltype;
    l_data varchar2(60);

begin
    --get rid of stuff before and after the envelope that makes this response to not be valid xml:
    select instr(p_clob, '<?xml version="1.0"') into l_start from DUAL;
    select instr(p_clob, '</env:Envelope>') into l_end from DUAL;
    select substr(p_clob, l_start, (l_end - l_start) +15 ) into l_clob from DUAL;

    --make the cleaned up clob an xmltype so we can parse as usual
    l_xml := XMLTYPE.createXML(l_clob);

    SELECT data  into l_data
       FROM 
       XMLTable(  
             XMLNamespaces(  
               'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV"  
                ,'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/' AS  "ns0" 
                , 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/' AS "ns2"
                
              ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/ns0:importBulkDataResponse/ns2:result' 
              passing   l_xml 
              columns data clob path '.'  
           );
                     
           
    return l_data;
           
    exception when others then
       record_error();

end parse_bulkload_response;

function parse_bulkload_error_response(p_clob IN clob)
    return varchar2
    
    is
    
    l_clob CLOB;
    l_start number;
    l_end number;
    l_data varchar2(1000);
    l_xml xmltype;

begin

    --get rid of stuff before and after the envelope that makes this response to not be valid xml:
    select instr(p_clob, '<?xml version="1.0"') into l_start from DUAL;
    select instr(p_clob, '</env:Envelope>') into l_end from DUAL;
    select substr(p_clob, l_start, (l_end - l_start) +15 ) into l_clob from DUAL;

    l_xml := XMLTYPE.createXML(l_clob);

    SELECT substr(data, instr(data, '<')) into l_data
       FROM 
       XMLTable(  
             XMLNamespaces(  
               'http://schemas.xmlsoap.org/soap/envelope/' AS "SOAP-ENV"  
               
              ), 'SOAP-ENV:Envelope/SOAP-ENV:Body/SOAP-ENV:Fault' 
              passing   l_xml 
              columns data path 'faultstring'  
           ) ;

    return l_data;

    exception when others then
        record_error();

end parse_bulkload_error_response;

function build_ess_envelope(p_ess_id IN number)
    return clob
    is
    
    l_envelope clob;

begin

    l_envelope := '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:sch="http://xmlns.oracle.com/scheduler">
       <soapenv:Header xmlns:wsa="http://www.w3.org/2005/08/addressing"><wsa:Action>getRequestState</wsa:Action><wsa:MessageID>uuid:a1d68933-e327-42d8-8cd1-1cc4abd830d7</wsa:MessageID></soapenv:Header>
       <soapenv:Body>
          <sch:getRequestState>
             <sch:requestId>'||p_ess_id||'</sch:requestId>
          </sch:getRequestState>
       </soapenv:Body>
    </soapenv:Envelope>';

    return l_envelope;

end build_ess_envelope;

function build_ess_envelope(p_job_package IN varchar2, p_job_definition IN varchar2)
    return clob
    
    is
    l_envelope    clob;
    
    begin
    l_envelope := '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:typ="http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/types/">
   <soapenv:Header/>
   <soapenv:Body>
      <typ:submitESSJobRequest>
         <typ:jobPackageName>'||p_job_package||'</typ:jobPackageName>
         <typ:jobDefinitionName>'||p_job_definition||'</typ:jobDefinitionName>
      </typ:submitESSJobRequest>
   </soapenv:Body>
</soapenv:Envelope>';

    return l_envelope;
     
    end build_ess_envelope;


PROCEDURE record_error
IS
   PRAGMA AUTONOMOUS_TRANSACTION;
   l_code   PLS_INTEGER := SQLCODE;
   l_mesg varchar2(32767) := SQLERRM; 
BEGIN
   INSERT INTO error_log (error_code
                        ,  error_message
                        ,  backtrace
                        ,  callstack
                        ,  created_on
                        ,  created_by)
        VALUES (l_code
              ,  l_mesg 
              ,  sys.DBMS_UTILITY.format_error_backtrace
              ,  sys.DBMS_UTILITY.format_call_stack
              ,  sysdate
              ,  V('APP_USER'));
   COMMIT;
END;

end "S1_UTILITIES_PKG";
