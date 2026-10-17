-- Does a 19 digit BIGINT survive the trip into R?
--
-- Each row carries the same value twice: once as BIGINT, once already cast to
-- text in SQL. checkDatabase() compares them. If the BIGINT
-- column arrives as a double, as.character() of it will differ from the text
-- column, which is the silent corruption this project is built to avoid.
SELECT 'two_pow_53_plus_1' AS label,
       CAST(9007199254740993 AS BIGINT) AS as_bigint,
       '9007199254740993' AS as_text
UNION ALL
SELECT 'mimic_example_positive',
       CAST(4672282447827634561 AS BIGINT),
       '4672282447827634561'
UNION ALL
SELECT 'mimic_example_negative',
       CAST(-7819202826128270750 AS BIGINT),
       '-7819202826128270750'
UNION ALL
SELECT 'bigint_max',
       CAST(9223372036854775807 AS BIGINT),
       '9223372036854775807'
;
