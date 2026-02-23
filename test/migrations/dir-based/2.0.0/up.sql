ALTER TABLE public.table1
    ADD COLUMN col3 VARCHAR;

ALTER TABLE public.table2
    ADD COLUMN col3 VARCHAR;

-- Add another table
CREATE TABLE public.table3 (
    id INT PRIMARY KEY,
    col1 VARCHAR,
    col2 VARCHAR,
    col3 VARCHAR
);