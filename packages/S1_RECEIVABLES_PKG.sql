create or replace package S1_RECEIVABLES_PKG as

function build_receivables_zip(p_demo_date IN date)
    return clob;

end;
