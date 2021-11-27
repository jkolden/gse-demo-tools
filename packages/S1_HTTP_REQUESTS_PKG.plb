create or replace package body "S1_HTTP_REQUESTS_PKG" is

procedure update_load_summary(p_type in varchar2, p_date IN date, p_ess_id IN number)
    is
    
    begin
    
    insert into ce_load_summary
            (instance, 
             demo_date, 
             ess_id,
             status, 
             type, 
             created_by, 
             creation_date) 
    values 
             (g_instance, 
              p_date, 
              p_ess_id, 
              'SUBMITTED', 
              p_type, 
              g_user, 
              sysdate);
              
    end update_load_summary;

procedure write_success_response

is

 begin
    apex_json.initialize_clob_output;
    apex_json.open_object;        -- {
    apex_json.write('code', 200);   
    apex_json.write('message', 'Success');
    apex_json.close_all;          --  ]
                          -- }

 end;
 
 procedure write_error_response(p_status_code IN number, p_description IN varchar2)

is
l_message     varchar2(240) := 'The files could not be loaded due to an error. The issue has been logged.';

 begin
    apex_json.initialize_clob_output;
    apex_json.open_object;        -- {
    apex_json.write('code', p_status_code); 
    apex_json.write('description', p_description);
    apex_json.write('message', l_message);
    apex_json.close_all;          --  ]
                          -- }

 end;

procedure make_soap_request(
    p_payload         IN  clob,
    p_soap_action     IN  varchar2 DEFAULT 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/importBulkData',
    p_integration_url IN  varchar2 DEFAULT '-'||g_domain||':443/fscmService/ErpIntegrationService',
    p_description     IN  varchar2,
    p_status_code     OUT number,
    p_soap_response   OUT clob
    )
        
    is
    http_request_failed EXCEPTION;
    PRAGMA EXCEPTION_INIT(http_request_failed, -29273);
   
    begin
    SELECT count(*) 
          INTO   g_count 
          FROM   apex_webservice_log 
          WHERE  apex_or_db_user = g_user 
          AND    request_date > SYSDATE - interval '24' hour; 
    
    if g_count < 500
    then
 --Submit SOAP API request:     
  apex_web_service.g_request_headers(1).name  := 'SOAPAction';
  apex_web_service.g_request_headers(1).value := p_soap_action;
  apex_web_service.g_request_headers(2).name  := 'Content-Type';
  apex_web_service.g_request_headers(2).value := 'text/xml; charset=UTF-8';

  p_soap_response := apex_web_service.make_rest_request (
    p_url              => 'https://'||g_instance||p_integration_url,
    p_http_method      => 'POST',
    p_body             => p_payload,
    p_proxy_override   => g_proxy,
    p_username         => g_cloud_submitter,
    p_transfer_timeout => 360,
    p_password         => g_password
  ); 
  
    end if;
    
    p_status_code := apex_web_service.g_status_code;
    
    --log the request if the API fails so we can debug the payloads
    if g_debug = true or p_status_code <> 200 
    then
    s1_utilities_pkg.log_http_request (
            p_payload     => p_payload, 
            p_response    => p_soap_response, 
            p_status_code => p_status_code,
            p_description => p_description,
            p_instance    => g_instance
          );
          
    end if;
    
    --server wasn't reached and thus we get no HTTP response code. This results in a plsql error so let's log it so we can debug.
    exception when http_request_failed
    then
        p_status_code := -1;
        
        s1_utilities_pkg.log_http_request (
            p_status_code => p_status_code,
            p_description => p_description||' - instance could not be reached via the web service. This is usually the result of attempting to contact an environment that does not exist',
            p_instance    => g_instance
          );
 
    when others then
           s1_utilities_pkg.record_error();
           
    end make_soap_request;

function load_bank_statements 
    return clob

is
    l_bank_statement_zip    clob;
    l_status_code           number;
    l_soap_response         clob;
    l_soap_payload          clob;
    l_ess_id                number;
    
begin

    --build_bank_statement_zip function returns a base 64 encoded zip file containing all the bank statements to be loaded for the given instance and statement date:
    
    l_bank_statement_zip := s1_bank_stmt_pkg.build_bank_statement_zip (
        p_instance         => g_instance, 
        p_statement_date   => g_statement_date
    );

    --Build xml payload for importBulkData SOAP web service for bank statements:
    dbms_lob.createtemporary(l_soap_payload, true, dbms_lob.session);
    
    l_soap_payload := s1_utilities_pkg.build_bulkdata_envelope (
        p_document_name     => 'UCMF'||XCC_UCM_SEQ.nextval, 
        p_filename          => 'BankStatements', 
        p_data              => l_bank_statement_zip, 
        p_account           => 'fin$/cashManagement$/import$', 
        p_file_type         => 'zip', 
        p_user              => g_cloud_submitter,
        p_interface_details => 5 --See https://confluence.oraclecorp.com/confluence/display/FFT/ERP+Connect+-+FBDI+Infrastructure+for+Integration#ERPConnect-FBDIInfrastructureforIntegration-ExistingConsumers
    );
           
    make_soap_request (
        p_payload         => l_soap_payload,
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response,
        p_description     => 'Bank Statements'
    );  
    
    dbms_lob.freetemporary(l_soap_payload);


    if l_status_code = 200
      then
         write_success_response;
      
        --the importBulkData soap api response contains the ess job id of the file load:
        l_ess_id := s1_utilities_pkg.parse_bulkload_response(l_soap_response);
        
        --used for the donut chart
        update ce_statement_headers 
           set ucm_filename = l_ess_id 
         where instance = g_instance 
           and statement_date = g_statement_date;     
        
        --used for the region that shows the ESS jobs and their status
        update_load_summary (
            p_type     => 'STATEMENTS', 
            p_date     => g_statement_date,
            p_ess_id   => l_ess_id
        );
    else
        write_error_response(
            p_status_code => l_status_code,
            p_description => 'Bank Statements');
                                      
    end if;
    
    return apex_json.get_clob_output;
    
    exception when others then
           s1_utilities_pkg.record_error();
                                                  
end load_bank_statements;

function load_receivables_invoices
    return clob    
    
    is
        l_receivables_file_zip  clob;
        l_status_code           number;
        l_soap_response         clob;
        l_soap_payload          clob;
        l_ess_id                number;
    
    begin
     
    dbms_lob.createtemporary(l_receivables_file_zip, true, dbms_lob.session);
    l_receivables_file_zip := s1_receivables_pkg.build_receivables_zip(g_demo_date);
    
    --Build xml payload for importBulkData SOAP web service for bank statements:
    dbms_lob.createtemporary(l_soap_payload, true, DBMS_LOB.SESSION);
    
    l_soap_payload := s1_utilities_pkg.build_bulkdata_envelope (
        p_document_name     => 'UCMF'||XCC_UCM_SEQ.nextval, 
        p_filename          => 'ArAutoinvoiceImport', 
        p_data              => l_receivables_file_zip, 
        p_account           => 'fin/receivables$/import$', 
        p_file_type         => 'zip', 
        p_user              => g_cloud_submitter,
        p_interface_details => 2 --See https://confluence.oraclecorp.com/confluence/display/FFT/ERP+Connect+-+FBDI+Infrastructure+for+Integration#ERPConnect-FBDIInfrastructureforIntegration-ExistingConsumers

    );
           
    make_soap_request (
        p_payload         => l_soap_payload,
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response,
        p_description     => 'Receivables Invoices'
    ); 
    
    dbms_lob.freetemporary(l_soap_payload);
    dbms_lob.freetemporary(l_receivables_file_zip);
                       
    if l_status_code = 200
      then
        write_success_response;
        
    --for the donut chart:
    insert into ra_interface_lines
        (transaction_number, 
         instance, 
         demo_date, 
         creation_date, 
         created_by) 
     select 
         transaction_number, 
         g_instance, 
         g_demo_date, 
         sysdate, 
         g_user
     from ra_interface_lines_master;
      
       --the importBulkData soap api response contains the ess job id of the file load:
       l_ess_id := s1_utilities_pkg.parse_bulkload_response(l_soap_response);
     
       --update the donut chart:
         update ra_interface_lines 
            set ucm_filename = l_ess_id 
          where instance = g_instance 
            and demo_date = g_demo_date;
            
        --used for the region that shows the ESS jobs and their status
        update_load_summary (
            p_type     => 'RECEIVABLES', 
            p_date     => g_demo_date,
            p_ess_id   => l_ess_id
        );
     else
         write_error_response(
            p_status_code => l_status_code,
            p_description => 'Receivables Invoices');
               
     end if;
     
     return apex_json.get_clob_output;
    
    exception when others then
           s1_utilities_pkg.record_error();
        
end load_receivables_invoices; 

function load_payables_invoices
    return clob
    
    is
        l_payables_zip     clob;
        l_status_code      number;
        l_soap_response    clob;
        l_soap_payload     clob;
        l_ess_id           number;
    
    begin
    
    dbms_lob.createtemporary(l_payables_zip, true, DBMS_LOB.SESSION);
    l_payables_zip := s1_payables_pkg.build_payables_zip(g_demo_date);
    
    dbms_lob.createtemporary(l_soap_payload, true, DBMS_LOB.SESSION);
    
    l_soap_payload := s1_utilities_pkg.build_bulkdata_envelope (
        p_document_name     => 'UCMF'||XCC_UCM_SEQ.nextval, 
        p_filename          => 'ApAutoinvoiceImport', 
        p_data              => l_payables_zip, 
        p_account           => 'fin/payables$/import$', 
        p_file_type         => 'zip', 
        p_user              => g_cloud_submitter,
        p_interface_details => 1 --See https://confluence.oraclecorp.com/confluence/display/FFT/ERP+Connect+-+FBDI+Infrastructure+for+Integration#ERPConnect-FBDIInfrastructureforIntegration-ExistingConsumers

    );
       
    make_soap_request (
        p_payload         => l_soap_payload,
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response,
        p_description     => 'Payables Invoices'
    );  
    
    dbms_lob.freetemporary(l_soap_payload);
    dbms_lob.freetemporary(l_payables_zip);
    
    if l_status_code = 200
      then
        write_success_response;
        
    --for the donut chart:
    insert into ap_interface_headers (
        invoice_number, 
        instance, 
        demo_date, 
        creation_date, 
        created_by) 
    select 
        invoice_number, 
        g_instance, 
        g_demo_date, 
        sysdate, 
        g_user
    from ap_interface_headers_master;
      
       --the importBulkData soap api response contains the ess job id of the file load:
       l_ess_id := s1_utilities_pkg.parse_bulkload_response(l_soap_response);
     
      --update the donut chart:
       update ap_interface_headers 
          set ucm_filename = l_ess_id 
        where instance = g_instance 
          and demo_date = g_demo_date;
          
        --used for the region that shows the ESS jobs and their status
        update_load_summary (
            p_type     => 'PAYABLES', 
            p_date     => g_demo_date,
            p_ess_id   => l_ess_id
        );
    else
        write_error_response(
            p_status_code => l_status_code,
            p_description => 'Payables Invoices');
           
    end if;

    return apex_json.get_clob_output;
    
    exception when others then
           s1_utilities_pkg.record_error();
    
    end load_payables_invoices;
    
    function load_blockchain_invoices
    return clob
    
    is
        l_payables_zip     clob;
        l_status_code      number;
        l_soap_response    clob;
        l_soap_payload     clob;
        l_ess_id           number;
    
    begin
    
    dbms_lob.createtemporary(l_payables_zip, true, DBMS_LOB.SESSION);
    l_payables_zip := s1_payables_blockchain_pkg.build_payables_zip(g_demo_date);
    
    dbms_lob.createtemporary(l_soap_payload, true, DBMS_LOB.SESSION);
    
    l_soap_payload := s1_utilities_pkg.build_bulkdata_envelope (
        p_document_name     => 'UCMF'||XCC_UCM_SEQ.nextval, 
        p_filename          => 'ApAutoinvoiceImport', 
        p_data              => l_payables_zip, 
        p_account           => 'fin/payables$/import$', 
        p_file_type         => 'zip', 
        p_user              => g_cloud_submitter,
        p_interface_details => 1 --See https://confluence.oraclecorp.com/confluence/display/FFT/ERP+Connect+-+FBDI+Infrastructure+for+Integration#ERPConnect-FBDIInfrastructureforIntegration-ExistingConsumers

    );
       
    make_soap_request (
        p_payload         => l_soap_payload,
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response,
        p_description     => 'Payables Invoices'
    );  
    
    dbms_lob.freetemporary(l_soap_payload);
    dbms_lob.freetemporary(l_payables_zip);
    
    if l_status_code = 200
      then
        write_success_response;
        
    --for the donut chart:
    insert into ap_interface_headers (
        invoice_number, 
        instance, 
        demo_date, 
        creation_date, 
        created_by) 
    select 
        invoice_number, 
        g_instance, 
        g_demo_date, 
        sysdate, 
        g_user
    from ap_interface_headers_master;
      
       --the importBulkData soap api response contains the ess job id of the file load:
       l_ess_id := s1_utilities_pkg.parse_bulkload_response(l_soap_response);
     
      --update the donut chart:
       update ap_interface_headers 
          set ucm_filename = l_ess_id 
        where instance = g_instance 
          and demo_date = g_demo_date;
          
        --used for the region that shows the ESS jobs and their status
        update_load_summary (
            p_type     => 'BLOCKCHAIN', 
            p_date     => g_demo_date,
            p_ess_id   => l_ess_id
        );
    else
        write_error_response(
            p_status_code => l_status_code,
            p_description => 'Payables Invoices');
           
    end if;

    return apex_json.get_clob_output;
    
    exception when others then
           s1_utilities_pkg.record_error();
    
    end load_blockchain_invoices;
    
function load_external_transactions
    return clob
    
    is
        l_external_txns    blob;
        l_zip              blob;
        l_base64           clob;
        l_status_code      number;
        l_soap_response    clob;
        l_soap_payload     clob;
        l_ess_id           number;
    
    begin
    
    dbms_lob.createtemporary(l_external_txns, true, DBMS_LOB.SESSION);
    
    l_external_txns := s1_utilities_pkg.get_csv (
        'select bank_account, amount,'''
        ||to_char(g_demo_date, 'MM/DD/YYYY')||''', 
        transaction_type, 
        reference_text, 
        business_unit, 
        accounting_flag 
        from ce_external_master');    
         
        apex_zip.add_file (
                p_zipped_blob => l_zip,
                p_file_name   => 'CeExternalTransactions.csv',
                p_content     => l_external_txns 
            );
            
        apex_zip.finish(l_zip);
        
        --convert zip to base64 for use in web service SOAP envelope:      
        l_base64 := apex_web_service.blob2clobbase64(l_zip);
        
        dbms_lob.createtemporary(l_soap_payload, true, DBMS_LOB.SESSION);
        
        l_soap_payload := s1_utilities_pkg.build_bulkdata_envelope (
        p_document_name     => 'UCMF'||XCC_UCM_SEQ.nextval, 
        p_filename          => 'CeExternalTransactions', 
        p_data              => l_base64, 
        p_account           => 'fin$/cashManagement$/import$', 
        p_file_type         => 'zip', 
        p_user              => g_cloud_submitter,
        p_interface_details => 50 --See https://confluence.oraclecorp.com/confluence/display/FFT/ERP+Connect+-+FBDI+Infrastructure+for+Integration#ERPConnect-FBDIInfrastructureforIntegration-ExistingConsumers

    );
    
    make_soap_request (
        p_payload         => l_soap_payload,
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response,
        p_description     => 'External Transactions'
    );  
    
    dbms_lob.freetemporary(l_soap_payload);
    dbms_lob.freetemporary(l_external_txns);
    
    if l_status_code = 200
      then
          write_success_response;
          
    --for the donut chart:
    insert into ce_external (
        transaction_date, 
        created_by, 
        instance, 
        amount, 
        reference_text) 
     (select 
         g_demo_date, 
         g_user, 
         g_instance, 
         amount, 
         reference_text 
         from 
         ce_external_master);
      
       --the importBulkData soap api response contains the ess job id of the file load:
       l_ess_id := s1_utilities_pkg.parse_bulkload_response(l_soap_response);
       
       --update the donut chart:
        update ce_external 
           set ucm_filename = l_ess_id 
         where instance = g_instance 
           and transaction_date = g_demo_date;
           
        --used for the region that shows the ESS jobs and their status
        update_load_summary (
            p_type     => 'EXTERNAL', 
            p_date     => g_demo_date,
            p_ess_id   => l_ess_id
        );
    else
        write_error_response(
            p_status_code => l_status_code,
            p_description => 'External Transactions');
       
   end if;
   
   return apex_json.get_clob_output;
    
    exception when others then
           s1_utilities_pkg.record_error();   

    end load_external_transactions;
    
function get_ess_status(p_ess_id IN number)
    return varchar2
    
    is
    l_soap_payload     clob;
    l_soap_response    clob;
    l_status_code      number;
    l_ess_status       varchar2(15);
    l_xml              xmltype;    
    
    begin
    l_soap_payload := s1_utilities_pkg.build_ess_envelope(p_ess_id);
    
    make_soap_request(
        p_payload         => l_soap_payload,
        p_soap_action     => 'getRequestState',
        p_integration_url => '-'|| g_domain ||':443/ess/esswebservice',
        p_description     => 'Ess Status Request',
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response
    );
    
    if l_status_code = 200
        then
            l_xml := XMLTYPE.createXML(l_soap_response);
            l_ess_status := s1_utilities_pkg.parse_ess_status_response(l_xml);
            update ce_load_summary set status = l_ess_status where ess_id = p_ess_id;
            return l_ess_status;
    end if;
    
    return null;
    
    exception when others then
           s1_utilities_pkg.record_error();
    
    end;
    
procedure submit_cash_extract

    is
    l_soap_payload                 clob;
    l_soap_response                clob;
    l_status_code                  number;
    l_job_definition   constant    varchar2(30) := 'CashPositionDataExtraction';
    l_job_package      constant    varchar2(100) := '/oracle/apps/ess/financials/cashManagement/cashPosition/integration/';
    l_ess_id                       number;
    
    begin
    
    l_soap_payload := s1_utilities_pkg.build_ess_envelope(
        p_job_definition => l_job_definition,
        p_job_package => l_job_package);
        
    make_soap_request(
        p_payload         => l_soap_payload,
        p_soap_action     => 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/submitESSJobRequest',
        p_integration_url => '-'|| g_domain ||':443/fscmService/ErpIntegrationService',
        p_description     => 'Ess Status Request',
        p_status_code     => l_status_code,
        p_soap_response   => l_soap_response
    );
    
    if l_status_code = 200
        then
        l_ess_id := s1_utilities_pkg.parse_ess_response(l_soap_response);
    
        insert into ce_load_summary (
            instance, 
            demo_date, 
            ess_id, 
            type, 
            creation_date,
            created_by) 
            values (
                g_instance, 
                g_demo_date, 
                l_ess_id, 
                'CASH', 
                sysdate, 
                V('APP_USER'));
    end if;
    
    exception when others then
           s1_utilities_pkg.record_error();
    
    end submit_cash_extract;

end "S1_HTTP_REQUESTS_PKG";
