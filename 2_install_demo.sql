

USE DATABASE CC_QUICKSTART_CORTEX_AGENTS;
USE SCHEMA PUBLIC;

create or replace stage docs ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE') DIRECTORY = ( ENABLE = true );

COPY FILES
    INTO @DOCS/
    FROM @CC_QUICKSTART_CORTEX_AGENTS.PUBLIC.git_repo_chatbot/branches/main/docs/
    PATTERN='.*[.]pdf';


ALTER STAGE DOCS REFRESH;

select * from directory(@docs);


create or replace function text_chunker(pdf_text string)
returns table (chunk varchar)
language python
runtime_version = '3.9'
handler = 'text_chunker'
packages = ('snowflake-snowpark-python', 'langchain')
as
$$
from snowflake.snowpark.types import StringType, StructField, StructType
from langchain.text_splitter import RecursiveCharacterTextSplitter
import pandas as pd

class text_chunker:

    def process(self, pdf_text: str):
        
        text_splitter = RecursiveCharacterTextSplitter(
            chunk_size = 1512, #Adjust this as you see fit
            chunk_overlap  = 256, #This let's text have some form of overlap. Useful for keeping chunks contextual
            length_function = len
        )
    
        chunks = text_splitter.split_text(pdf_text)
        df = pd.DataFrame(chunks, columns=['chunks'])
        
        yield from df.itertuples(index=False, name=None)
$$;

create or replace TABLE DOCS_CHUNKS_TABLE ( 
    RELATIVE_PATH VARCHAR(16777216), -- Relative path to the PDF file
    SIZE NUMBER(38,0), -- Size of the PDF
    FILE_URL VARCHAR(16777216), -- URL for the PDF
    SCOPED_FILE_URL VARCHAR(16777216), -- Scoped url (you can choose which one to keep depending on your use case)
    CHUNK VARCHAR(16777216), -- Piece of text
    CATEGORY VARCHAR(16777216) -- Will hold the document category to enable filtering
);

insert into docs_chunks_table (relative_path, size, file_url,
                            scoped_file_url, chunk)
    select relative_path, 
            size,
            file_url, 
            build_scoped_file_url(@docs, relative_path) as scoped_file_url,
            func.chunk as chunk
    from 
        directory(@docs),
        TABLE(text_chunker (TO_VARCHAR(SNOWFLAKE.CORTEX.PARSE_DOCUMENT(@docs, 
                              relative_path, {'mode': 'LAYOUT'})))) as func;


CREATE
OR REPLACE TEMPORARY TABLE docs_categories AS WITH unique_documents AS (
  SELECT
    DISTINCT relative_path
  FROM
    docs_chunks_table
),
docs_category_cte AS (
  SELECT
    relative_path,
    TRIM(snowflake.cortex.COMPLETE (
      'llama3-70b',
      'Given the name of the file between <file> and </file> determine if it is related to bikes or snow. Use only one word <file> ' || relative_path || '</file>'
    ), '\n') AS category
  FROM
    unique_documents
)
SELECT
  *
FROM
  docs_category_cte;

select category from docs_categories group by category;

update docs_chunks_table 
  SET category = docs_categories.category
  from docs_categories
  where  docs_chunks_table.relative_path = docs_categories.relative_path;


create or replace CORTEX SEARCH SERVICE CC_SEARCH_SERVICE_CS
ON chunk
ATTRIBUTES category
warehouse = COMPUTE_WH
TARGET_LAG = '1 minute'
as (
    select chunk,
        relative_path,
        file_url,
        category
    from docs_chunks_table
);

ALTER GIT REPOSITORY git_repo_chatbot FETCH;

-- Create stage for App logic and 3rd party packages
CREATE OR REPLACE STAGE STREAMLIT_STAGE
DIRECTORY = (ENABLE = true)
COMMENT = '{"origin": "sf_chatbot",
            "name": "chatbot",
            "version": {"major": 1, "minor": 0},
            "attributes": {"deployment": "sis"}}';

COPY FILES 
    INTO @STREAMLIT_STAGE
    FROM @CC_QUICKSTART_CORTEX_AGENTS.PUBLIC.git_repo_chatbot/branches/main/
    FILES =('streamlit_chatbot.py', 'environment.yml');

ALTER STAGE STREAMLIT_STAGE REFRESH;

CREATE OR REPLACE STREAMLIT STREAMLIT_CHATBOT
    ROOT_LOCATION = '@STREAMLIT_STAGE'
    MAIN_FILE = 'streamlit_chatbot.py'
    TITLE = 'DOCUMENT CHATBOT'
    QUERY_WAREHOUSE = 'COMPUTE_WH'
    COMMENT = '{"origin": "sf_chatbot",
            "name": "chatbot",
            "version": {"major": 1, "minor": 0},
            "attributes": {"deployment": "sis"}}';  

------- Setup for Analyst:

CREATE OR REPLACE TABLE DIM_ARTICLE (
    ARTICLE_ID INT PRIMARY KEY,
    ARTICLE_NAME STRING,
    ARTICLE_PRICE FLOAT  -- Fixed price for each article
);

insert into DIM_ARTICLE (ARTICLE_ID, ARTICLE_NAME, ARTICLE_PRICE)
values 
(1, 'Mondracer Infant Bike', 3000),
(2, 'Premium Bycycle', 9000),
(3, 'Ski Boots TDBootz Special', 600),
(4, 'The Ultimate Downhill Bike', 10000),
(5, 'The Xtreme Road Bike 105 SL', 8500),
(6, 'Carver Skis', 790),
(7, 'Outpiste Skis', 900),
(8, 'Racing Fast Skis',950)
;

CREATE or replace TABLE DIM_CUSTOMER (
    CUSTOMER_ID INT PRIMARY KEY,
    CUSTOMER_NAME STRING,
    CUSTOMER_REGION STRING
);

CREATE or replace TABLE FACT_SALES (
    SALE_ID INT PRIMARY KEY,
    ARTICLE_ID INT,
    DATE_SALES DATE,
    CUSTOMER_ID INT,
    QUANTITY_SOLD INT,
    TOTAL_PRICE FLOAT,
    FOREIGN KEY (ARTICLE_ID) REFERENCES DIM_ARTICLE(ARTICLE_ID),
    FOREIGN KEY (CUSTOMER_ID) REFERENCES DIM_CUSTOMER(CUSTOMER_ID)
);

INSERT INTO DIM_CUSTOMER (CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_REGION)
SELECT SEQ4() AS CUSTOMER_ID,
       'Customer ' || SEQ4() AS CUSTOMER_NAME,
       CASE MOD(SEQ4(), 5)
            WHEN 0 THEN 'North'
            WHEN 1 THEN 'South'
            WHEN 2 THEN 'East'
            WHEN 3 THEN 'West'
            ELSE 'Central'
       END AS CUSTOMER_REGION
FROM TABLE(GENERATOR(ROWCOUNT => 5000));


INSERT INTO FACT_SALES (SALE_ID, ARTICLE_ID, DATE_SALES, CUSTOMER_ID, QUANTITY_SOLD, TOTAL_PRICE)
SELECT SEQ4() AS SALE_ID,
       A.ARTICLE_ID,
       DATEADD(DAY, UNIFORM(-1095, 0, RANDOM()), CURRENT_DATE) AS DATE_SALES,  
       UNIFORM(1, 5000, RANDOM()) AS CUSTOMER_ID,   -- Random date
       UNIFORM(1, 10, RANDOM()) AS QUANTITY_SOLD,  -- Random quantity (1-10)
       QUANTITY_SOLD * A.ARTICLE_PRICE AS TOTAL_PRICE  -- Fixed price from DIM_ARTICLE
FROM DIM_ARTICLE A
JOIN TABLE(GENERATOR(ROWCOUNT => 10000)) ON TRUE
ORDER BY DATE_SALES;  -- Randomize sales order


create stage semantic directory = (enable = TRUE);

COPY FILES 
    INTO @semantic
    FROM @CC_QUICKSTART_CORTEX_AGENTS.PUBLIC.git_repo_chatbot/branches/main/
    FILES =('sales_semantic.yaml');

CREATE OR REPLACE CORTEX SEARCH SERVICE article_name_search_service
  ON ARTICLE_DIMENSION
  WAREHOUSE = compute_wh
  TARGET_LAG = '1 hour'
  AS (
      SELECT DISTINCT ARTICLE_NAME AS ARTICLE_DIMENSION FROM DIM_ARTICLE
  );


  