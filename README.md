# GSE Demo Tools
This code represents a sample of the PL/SQL used to support the GSE demo tools. The GSE demo tools are a series of APEX applications hosted on apex.oraclecorp.com that allow solution engineers to quickly stage demo data for various ERP subject areas, i.e. Cash Management, Credit Card Expenses and Revenue Management.

## Purpose of the GSE Demo Tools
Most of the data needed to present a complete ERP demo is time-sensitive. Further, this data is typically consumed during the demo itself and therefore new and fresh data is required for each successive demo. Before these tools were created, solution engineers were required to load their demo data using FBDI (File Based Data Import) spreadsheets. This is extremely time-consuming and error-prone and can take several hours to load all the required transactions for an ERP demo. With these demo tools we can stage a demo in minutes with just the click of a button.

<img width="1433" alt="tools_screen_shot" src="https://user-images.githubusercontent.com/21246211/143778287-5e4e6d43-d319-4b0a-9246-2ef0b106d581.png">

## How the code is used by the APEX demo tools applications
The entry point to this code is the s1_http_requests_pkg package. The solution engineer will use the APEX app to enter their demo environment identifier and the environment password. They will then select a bank statement date (which is typically the date prior to their demo) and the date of the actual demo. The APEX application will then make server requests to the following procedures of the s1_http_requests_pkg package for the dates specified:

* load_bank_statements
* load_receivables_invoices
* load_payables_invoices
* load_external_transactions

The s1_http_requests_pkg is responsible for making the actual SOAP HTTP requests and processing the response, but the SOAP payloads themselves are built by functions in separate packages that return a CLOB which is then used in the content tag of the SOAP payload. **For purposes of example I've included the s1_receivables_pkg to just give an idea as to how the payloads are built.** 

The process for each of these areas consists of 
* selecting records from a table into a CSV BLOB datatype 
* zipping the CSV BLOB
* converting the zip to a base64 CLOB
* The base64 is used in the content tag of the importBulkData API

## APIs Used by the Demo Tools Application
The main API we use to send data to ERP cloud is the [importBulkData](https://docs.oracle.com/en/cloud/saas/financials/21d/oeswf/Chunk1914622151.html#erpintegrationservice) method of ERP Integration Service. This is an extremely useful and powerful API but it can be tricky to consume as the required payloads are quite detailed. The main reason this API is so powerful is because it automates the ERP File-Based Data Import and also allows us to send an associated properties file that specifies which ESS jobs should be run after the import process completes. For example if we use importBulkData to load Accounts Payable invoices, we can also request the API to validate those invoices and then run the accounting processes as soon as the import is complete. Thus many tasks can be performed in the proper order with just one API call.
