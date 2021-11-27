create or replace package body "S1_BANK_STMT_PKG" is

--Creates a BAI2 formatted bank statement text file for inclusion in a zip file which in turn is passed to the importBulkData API
--More info about the BAI2 file format can be found here: https://www.bai.org/docs/default-source/libraries/site-general-downloads/cash_management_2005.pdf
function build_bank_statement(p_header_id IN number)
     return blob
is
     l_statement_header ce_statement_headers%ROWTYPE;
     l_line_sum number;
     l_line_count number;
     l_bank_statement blob;
     l_line_01 blob;
     l_line_02 blob;
     l_line_03 blob;
     l_line_16 blob;
     l_line_16_concat blob;
     l_line_49 blob;
     l_line_98 blob;
     l_line_99 blob;
     l_net_debits number; --payments (type_code 475)
     l_net_credits number; --deposits (type code 100)
     l_ending_balance number;

begin

     dbms_lob.createtemporary( l_line_16_concat, FALSE );
     dbms_lob.open( l_line_16_concat, dbms_lob.lob_readwrite );

     dbms_lob.createtemporary( l_bank_statement, FALSE );
     dbms_lob.open( l_bank_statement, dbms_lob.lob_readwrite );

     --select into row record variable for use in lines 01, 02 and 03
     Select * into l_statement_header from ce_statement_headers where header_id = p_header_id;

     --for use in line 03
     select sum(amount) * 100 into l_line_sum from ce_statement_lines where header_id = p_header_id;

     --Compute ending balance for use in Line 03:
     select nvl(sum(amount), 0) into l_net_credits from ce_statement_lines where header_id = p_header_id and type_code IN ('100', '354');
     select nvl(sum(amount), 0) into l_net_debits  from ce_statement_lines where header_id = p_header_id and type_code IN ('475', '698');


     l_ending_balance := l_statement_header.opening_balance + l_net_credits - l_net_debits;

     --for use in lines 49, 98 and 99
     select count(*) into l_line_count from ce_statement_lines where header_id = p_header_id;
                        
     l_line_01 := s1_utilities_pkg.get_csv('select ''01'', '
                              ||l_statement_header.sender_id
                              ||','
                              ||l_statement_header.sender_id
                              ||', '
                              ||to_char(l_statement_header.statement_date, 'YYMMDD')
                              ||', ''0201'', '
                              ||l_statement_header.file_id_number
                              ||', null, null, ''2/'' from DUAL');                         

     l_line_02 := s1_utilities_pkg.get_csv('select ''02'', 509, 509, 1,'
                              ||to_char(l_statement_header.statement_date, 'YYMMDD')
                              ||', 2400, '''
                              ||l_statement_header.currency_code
                              ||''', ''0/'' from DUAL');                            
                        
     l_line_03 := s1_utilities_pkg.get_csv('select ''03'', '''
                              ||l_statement_header.cust_account_number
                              ||''', '''
                              ||l_statement_header.currency_code
                              ||''', ''010'', '
                              ||l_statement_header.opening_balance * 100
                              ||', null, ''S'', null, null, null, ''015'', '
                              ||l_ending_balance * 100
                              ||', null, ''S'', null, null, null, null, null, null, null, null, null, null, null, ''/'' from DUAL' );
                                                      
     --loop over all detail line records and create a '16' record for each
     for detail_rec IN (Select * from ce_statement_lines where header_id = p_header_id)

          loop
               l_line_16 := s1_utilities_pkg.get_csv('select ''16'', '||detail_rec.type_code||', '||detail_rec.amount * 100||', 0, '''||detail_rec.bank_ref_number||''', '''||detail_rec.customer_reference_number||''', '''||detail_rec.text||''' from DUAL' );
               dbms_lob.append(l_line_16_concat, l_line_16);
               l_line_sum := l_line_sum + detail_rec.amount;

          end loop;

     l_line_49 := s1_utilities_pkg.get_csv('select ''49'', '
                              ||l_line_sum
                              ||', ''3/'' from DUAL' );
     l_line_98 := s1_utilities_pkg.get_csv('select ''98'', '
                              ||l_line_sum
                              ||', 1, ''5/'' from DUAL' );
     l_line_99 := s1_utilities_pkg.get_csv('select ''99'', '
                              ||l_line_sum
                              ||', 1, ''7/'' from DUAL');
                                                                          
     dbms_lob.append(l_bank_statement, l_line_01); 
     dbms_lob.append(l_bank_statement, l_line_02);
     dbms_lob.append(l_bank_statement, l_line_03);
     dbms_lob.append(l_bank_statement, l_line_16_concat);
     dbms_lob.append(l_bank_statement, l_line_49);
     dbms_lob.append(l_bank_statement, l_line_98);
     dbms_lob.append(l_bank_statement, l_line_99);

     return l_bank_statement;
     
     exception when others then
           s1_utilities_pkg.record_error();

end build_bank_statement;

function build_bank_statement_zip(p_instance IN varchar2, p_statement_date IN date)
    return clob
    
  is
   l_count             number;
   l_properties        blob;
   l_bank_statement    blob;
   l_base64            clob;
   l_zip               blob;
 
begin
    
  select Count(*) 
    into l_count 
    from ce_statement_headers 
   where instance = p_instance
     and statement_date = p_statement_date 
     and ucm_filename is null; 

  if ( l_count = 0 ) then 
      return null;
  end if;    

  --build properties file for inclusion in the zip file. This tells the API which ESS jobs to run after the import is complete
   l_properties := s1_utilities_pkg.get_csv('select ''oracle/apps/ess/financials/cashManagement/cashPosition/integration'',
                              ''CashPositionDataExtraction''
                               from DUAL');

  --loop over each bank statement and add to the zip file:
  for c1 in (select header_id, account_description from ce_statement_headers 
             where instance = p_instance
             and statement_date = p_statement_date
             and ucm_filename is null
             )
    loop

        dbms_lob.createtemporary( l_bank_statement, FALSE );
        dbms_lob.open( l_bank_statement, dbms_lob.lob_readwrite );

        l_bank_statement := build_bank_statement(c1.header_id);
                            
    --create zip file and free the temp blob l_bank_statement:
        apex_zip.add_file (
            p_zipped_blob => l_zip,
            p_file_name   => c1.account_description||'.txt',
            p_content     => l_bank_statement 
        ); 
                      
        dbms_lob.close(l_bank_statement);
        
    end loop;

        apex_zip.add_file (
            p_zipped_blob => l_zip, 
            p_file_name   => 'BankStatements.properties', 
            p_content     => l_properties); 
                      
        apex_zip.finish(p_zipped_blob => l_zip);
    
    --convert zip to base64 for use in web service SOAP envelope:      
    l_base64 := apex_web_service.blob2clobbase64(l_zip);

    return l_base64;

  exception when others then
             s1_utilities_pkg.record_error();

end build_bank_statement_zip;

procedure create_from_templates(p_instance IN varchar2, p_statement_date IN date)

    is
    
    begin
    
merge into ce_statement_headers d 
using (select m.sender_id, 
              m.file_id_number, 
              m.cust_account_number, 
              m.account_description, 
              m.opening_balance, 
              m.currency_code, 
              h.header_id, 
              h.instance, 
              h.statement_date 
       from   ce_statement_headers_master m 
              left outer join ce_statement_headers h 
                           on m.cust_account_number = h.cust_account_number 
                              and h.statement_date = p_statement_date 
                              and h.instance = p_instance) s 
on (d.statement_date = p_statement_date and d.instance = p_instance and d.cust_account_number = s.cust_account_number) 
when not matched then 
  insert ( d.header_id, 
           d.sender_id, 
           d.file_id_number, 
           d.cust_account_number, 
           d.account_description, 
           d.opening_balance, 
           d.currency_code, 
           d.statement_date, 
           d.instance, 
           d.creation_date, 
           d.created_by) 
  values (ce_headers.NEXTVAL, 
          s.sender_id, 
          s.file_id_number, 
          s.cust_account_number, 
          s.account_description, 
          s.opening_balance, 
          s.currency_code, 
          p_statement_date, 
          p_instance, 
          SYSDATE, 
          V('APP_USER')); 

merge into ce_statement_lines d 
using (select h.header_id header_seq, 
              l.line_id, 
              h.instance, 
              h.statement_date, 
              mh.cust_account_number, 
              ml.header_id, 
              ml.line_id  master_line_id, 
              ml.type_code, 
              ml.amount, 
              ml.bank_ref_number, 
              ml.customer_reference_number, 
              ml.text 
       from   ce_statement_headers_master mh 
              left outer join ce_statement_lines_master ml 
                           on mh.header_id = ml.header_id 
              left outer join ce_statement_headers h 
                           on h.cust_account_number = mh.cust_account_number 
                              and h.instance = p_instance 
                              and h.statement_date = p_statement_date
              left outer join ce_statement_lines l 
                           on ml.line_id = l.line_id 
                              and l.header_id = h.header_id) s 
on (s.statement_date = p_statement_date and s.instance = p_instance AND 
d.header_id = s.header_seq and d.master_line_id = s.master_line_id) 
when not matched then 
  insert (d.header_id, 
          d.line_id, 
          d.master_line_id, 
          d.type_code, 
          d.amount, 
          d.bank_ref_number, 
          d.customer_reference_number, 
          d.text, 
          d.creation_date, 
          d.created_by) 
  values ( s.header_seq, 
           ce_lines.NEXTVAL, 
           s.master_line_id, 
           s.type_code, 
           s.amount, 
           s.bank_ref_number, 
           s.customer_reference_number, 
           s.text, 
           SYSDATE, 
           V('APP_USER')); 
           
end create_from_templates;

procedure create_from_templates_test(p_instance IN varchar2, p_statement_date IN date)

    is
    
    begin
    
merge into ce_statement_headers d 
using (select m.sender_id, 
              m.file_id_number, 
              m.cust_account_number, 
              m.account_description, 
              m.opening_balance, 
              m.currency_code, 
              h.header_id, 
              h.instance, 
              h.statement_date 
       from   ce_headers_master_test m 
              left outer join ce_statement_headers h 
                           on m.cust_account_number = h.cust_account_number 
                              and h.statement_date = p_statement_date 
                              and h.instance = p_instance) s 
on (d.statement_date = p_statement_date and d.instance = p_instance and d.cust_account_number = s.cust_account_number) 
when not matched then 
  insert ( d.header_id, 
           d.sender_id, 
           d.file_id_number, 
           d.cust_account_number, 
           d.account_description, 
           d.opening_balance, 
           d.currency_code, 
           d.statement_date, 
           d.instance, 
           d.creation_date, 
           d.created_by) 
  values (ce_headers.NEXTVAL, 
          s.sender_id, 
          s.file_id_number, 
          s.cust_account_number, 
          s.account_description, 
          s.opening_balance, 
          s.currency_code, 
          p_statement_date, 
          p_instance, 
          SYSDATE, 
          V('APP_USER')); 

merge into ce_statement_lines d 
using (select h.header_id header_seq, 
              l.line_id, 
              h.instance, 
              h.statement_date, 
              mh.cust_account_number, 
              ml.header_id, 
              ml.line_id  master_line_id, 
              ml.type_code, 
              ml.amount, 
              ml.bank_ref_number, 
              ml.customer_reference_number, 
              ml.text 
       from   ce_headers_master_test mh 
              left outer join ce_statement_lines_master ml 
                           on mh.header_id = ml.header_id 
              left outer join ce_statement_headers h 
                           on h.cust_account_number = mh.cust_account_number 
                              and h.instance = p_instance 
                              and h.statement_date = p_statement_date
              left outer join ce_statement_lines l 
                           on ml.line_id = l.line_id 
                              and l.header_id = h.header_id) s 
on (s.statement_date = p_statement_date and s.instance = p_instance AND 
d.header_id = s.header_seq and d.master_line_id = s.master_line_id) 
when not matched then 
  insert (d.header_id, 
          d.line_id, 
          d.master_line_id, 
          d.type_code, 
          d.amount, 
          d.bank_ref_number, 
          d.customer_reference_number, 
          d.text, 
          d.creation_date, 
          d.created_by) 
  values ( s.header_seq, 
           ce_lines.NEXTVAL, 
           s.master_line_id, 
           s.type_code, 
           s.amount, 
           s.bank_ref_number, 
           s.customer_reference_number, 
           s.text, 
           SYSDATE, 
           V('APP_USER')); 
           
end create_from_templates_test;

procedure create_from_templates_le(p_instance IN varchar2, p_statement_date IN date, p_le IN varchar2)

    is
    
    begin
    
merge into ce_statement_headers d 
using (select m.sender_id, 
              m.legal_entity,
              m.file_id_number, 
              m.cust_account_number, 
              m.account_description, 
              m.opening_balance, 
              m.currency_code, 
              h.header_id, 
              h.instance, 
              h.statement_date 
       from   ce_headers_master_le m 
              left outer join ce_statement_headers h 
                           on m.cust_account_number = h.cust_account_number 
                              and h.statement_date = p_statement_date 
                              and h.instance = p_instance
      where instr(':'||p_le||':',':'||m.legal_entity||':') > 0) s 
on (d.statement_date = p_statement_date and d.instance = p_instance and d.cust_account_number = s.cust_account_number) 
when not matched then 
  insert ( d.header_id, 
           d.sender_id, 
           d.legal_entity,
           d.file_id_number, 
           d.cust_account_number, 
           d.account_description, 
           d.opening_balance, 
           d.currency_code, 
           d.statement_date, 
           d.instance, 
           d.creation_date, 
           d.created_by) 
  values (ce_headers.NEXTVAL, 
          s.sender_id, 
          s.legal_entity,
          s.file_id_number, 
          s.cust_account_number, 
          s.account_description, 
          s.opening_balance, 
          s.currency_code, 
          p_statement_date, 
          p_instance, 
          SYSDATE, 
          V('APP_USER')); 

merge into ce_statement_lines d 
using (select h.header_id header_seq, 
              l.line_id, 
              h.instance, 
              h.statement_date, 
              mh.cust_account_number, 
              ml.header_id, 
              ml.line_id  master_line_id, 
              ml.type_code, 
              ml.amount, 
              ml.bank_ref_number, 
              ml.customer_reference_number, 
              ml.text 
       from   ce_headers_master_le mh 
              left outer join ce_statement_lines_master ml 
                           on mh.header_id = ml.header_id 
              left outer join ce_statement_headers h 
                           on h.cust_account_number = mh.cust_account_number 
                              and h.instance = p_instance 
                              and h.statement_date = p_statement_date
              left outer join ce_statement_lines l 
                           on ml.line_id = l.line_id 
                              and l.header_id = h.header_id) s 
on (s.statement_date = p_statement_date and s.instance = p_instance AND 
d.header_id = s.header_seq and d.master_line_id = s.master_line_id) 
when not matched then 
  insert (d.header_id, 
          d.line_id, 
          d.master_line_id, 
          d.type_code, 
          d.amount, 
          d.bank_ref_number, 
          d.customer_reference_number, 
          d.text, 
          d.creation_date, 
          d.created_by) 
  values ( s.header_seq, 
           ce_lines.NEXTVAL, 
           s.master_line_id, 
           s.type_code, 
           s.amount, 
           s.bank_ref_number, 
           s.customer_reference_number, 
           s.text, 
           SYSDATE, 
           V('APP_USER')); 
           
end create_from_templates_le;
    

end "S1_BANK_STMT_PKG";
