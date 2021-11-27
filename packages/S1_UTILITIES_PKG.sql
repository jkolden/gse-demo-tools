create or replace package s1_utilities_pkg as

procedure log_http_request (
    p_payload      IN  clob, 
    p_response     IN  clob, 
    p_status_code  IN  number, 
    p_description  IN  varchar2,
    p_instance     IN  varchar2
    );
    
    procedure log_http_request (
    p_status_code  IN  number, 
    p_description  IN  varchar2,
    p_instance     IN  varchar2
    );

function get_user_initials
    return varchar2;

 -- generates a column-separated blob for a sql query passed in as the input parameter
function get_csv(p_query in varchar2)
    return blob;

 -- Parses the SOAP payload from bip report service
function parse_bip_response(p_clob IN clob)
   return clob;
   
 -- Parses the SOAP payload from ErpIntegrationService
function parse_ess_response(p_clob IN clob)
  return number;
  
function parse_ess_status_response(p_xml in xmltype)
    return varchar2;
  
 -- Builds the xml payload for the SOAP API importBulkData
function build_bulkdata_envelope(p_document_name IN varchar2, p_filename IN varchar2, p_data IN clob, p_account IN varchar2, p_file_type IN varchar2 , p_user IN varchar2, p_interface_details IN number)
   return clob;

--parses the bulkload response when the request is successful, i.e. status 200
function parse_bulkload_response (p_clob IN clob)
   return varchar2;
   
--parses the bulkload response when the status code is 401 or 500
function parse_bulkload_error_response(p_clob IN clob)
   return varchar2;
   
function build_ess_envelope(p_ess_id IN number)
    return clob;
    
function build_ess_envelope(p_job_package IN varchar2, p_job_definition IN varchar2)
    return clob;
   
procedure record_error;


end;
