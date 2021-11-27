create or replace package S1_BANK_STMT_PKG as

function build_bank_statement_zip(p_instance IN varchar2, p_statement_date IN date)
    return clob;

procedure create_from_templates(p_instance IN varchar2, p_statement_date IN date);

procedure create_from_templates_test(p_instance IN varchar2, p_statement_date IN date);

procedure create_from_templates_le(p_instance IN varchar2, p_statement_date IN date, p_le IN varchar2);


    
end;
