WITH user_first_purchase AS (
  SELECT user_id, DATE_TRUNC(DATE(MIN(created_at)), MONTH) AS cohort_month
  FROM `bigquery-public-data.thelook_ecommerce.orders`
  WHERE status NOT IN ('Cancelled', 'Returned')
  GROUP BY 1
),
retention_data AS (
  SELECT
    ufp.cohort_month,
    DATE_DIFF(DATE_TRUNC(DATE(o.created_at), MONTH), ufp.cohort_month, MONTH) AS month_number,
    COUNT(DISTINCT o.user_id) AS active_users
  FROM `bigquery-public-data.thelook_ecommerce.orders` o
  JOIN user_first_purchase ufp ON o.user_id = ufp.user_id
  WHERE o.status NOT IN ('Cancelled', 'Returned')
  GROUP BY 1, 2
)
SELECT r.*, ROUND((r.active_users / s.total_users) * 100, 2) AS retention_rate
FROM retention_data r
JOIN (SELECT cohort_month, COUNT(DISTINCT user_id) AS total_users FROM user_first_purchase GROUP BY 1) s 
  ON r.cohort_month = s.cohort_month
ORDER BY 1 DESC, 2;