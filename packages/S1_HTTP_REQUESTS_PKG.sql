create or replace package S1_HTTP_REQUESTS_PKG as

    g_instance                  varchar2(30);
    g_domain                    varchar2(120) default 'fa-ext.oracledemos.com';
    g_password                  varchar2(15);
    g_statement_date            date;
    g_demo_date                 date;
    g_debug                     boolean;
    g_user             CONSTANT varchar2(60 char) := V('APP_USER');
    g_cloud_submitter  CONSTANT varchar2(60 char) := 'casey.brown';
    g_proxy            CONSTANT varchar2(30)      := 'pdit-b2b-proxy.oraclecorp.com';
    g_count                     number;

function load_bank_statements
    return clob;
    
function load_receivables_invoices
    return clob;
    
function load_payables_invoices
    return clob;
    
function load_blockchain_invoices
    return clob;

function load_external_transactions
    return clob;
    
function get_ess_status(p_ess_id IN number)
    return varchar2;
    
procedure submit_cash_extract;   

procedure make_soap_request(
    p_payload         IN  clob,
    p_soap_action     IN  varchar2 DEFAULT 'http://xmlns.oracle.com/apps/financials/commonModules/shared/model/erpIntegrationService/importBulkData',
    p_integration_url IN  varchar2 DEFAULT '-'||g_domain||':443/fscmService/ErpIntegrationService',
    p_description     IN  varchar2,
    p_status_code     OUT number,
    p_soap_response   OUT clob
    );

end;
