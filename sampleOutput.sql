[HCM Final Output]:
```sql
WITH employee_po_filter AS (
    -- 1. Identify POs for items in the specified category ('IT Equipment')
    SELECT DISTINCT
        ph.po_header_id,
        ph.creator_id AS employee_id
    FROM
        po_headers_b ph
    JOIN
        po_lines_b pl ON ph.po_header_id = pl.po_header_id
    JOIN
        -- Assuming item category is linked via the standard inventory tables
        mtl_system_items_b msi ON pl.inventory_item_id = msi.inventory_item_id
    WHERE
        msi.category_name = 'IT Equipment'
),
employee_details AS (
    -- 2. Get active employee names linked to the qualified POs
    SELECT
        ppf.first_name,
        ppf.last_name,
        ppf.person_id
    FROM
        per_all_people_f ppf
    JOIN
        employee_po_filter epf ON ppf.person_id = epf.employee_id
    WHERE
        -- Filter for currently active employees (assuming current date is effective)
        ppf.effective_end_date > SYSDATE
),
paid_invoice_amounts AS (
    -- 3. Calculate the total fully paid amount against these POs
    SELECT
        pci.po_header_id,
        SUM(pai.amount_paid) AS total_paid_amount
    FROM
        ap_invoices_all pai
    JOIN
        ap_invoice_lines_all ail ON pai.invoice_id = ail.invoice_id
    JOIN
        -- Link invoice lines back to the PO header
        po_distributions pd ON ail.invoice_line_id = pd.invoice_line_id
    JOIN
        employee_po_filter epf ON pd.po_header_id = epf.po_header_id
    WHERE
        pai.payment_status_code = 'PAID' -- Filter for fully paid invoices
    GROUP BY
        pci.po_header_id
)
-- 4. Final aggregation: Join employee details with the total paid amounts
SELECT
    ed.first_name,
    ed.last_name,
    SUM(pia.total_paid_amount) AS total_fully_paid_invoice_amount
FROM
    employee_details ed
JOIN
    paid_invoice_amounts pia ON ed.person_id = (SELECT employee_id FROM employee_po_filter WHERE po_header_id = pia.po_header_id LIMIT 1) -- Simplified join logic based on PO link
GROUP BY
    ed.first_name,
    ed.last_name
ORDER BY
    total_fully_paid_invoice_amount DESC;
```


[SCM Final Output]:
```sql
WITH Employee_PO_Creators AS (
    -- 1. Identify unique employees who created a PO containing 'IT Equipment' items
    SELECT DISTINCT
        poh.created_by AS employee_id,
        poh.po_header_id
    FROM
        po_headers_all poh
    JOIN
        po_lines_all pla ON poh.po_header_id = pla.po_header_id
    JOIN
        mtl_system_items_b msi ON pla.inventory_item_id = msi.inventory_item_id
    WHERE
        msi.item_category_name LIKE '%IT Equipment%'
        -- Assuming 'created_by' holds the employee ID (User ID)
),
Total_Paid_Invoices AS (
    -- 2. Calculate the total amount fully paid against the POs identified above
    SELECT
        epc.po_header_id,
        SUM(apfa.invoice_amount * apfa.payment_percentage) AS total_paid_amount -- Simplified calculation assuming payment details are available or using a direct sum of payments applied
    FROM
        ap_invoices_all apfa
    JOIN
        employee_po_creators epc ON apfa.po_header_id = epc.po_header_id
    WHERE
        -- Filter for invoices that have been fully paid (or where payment records exist)
        apfa.invoice_status_code IN ('PAID', 'CLOSED') 
        AND apfa.payment_amount > 0 -- Ensure some amount was actually paid
    GROUP BY
        epc.po_header_id
)
SELECT
    p.first_name,
    p.last_name,
    NVL(SUM(tpi.total_paid_amount), 0) AS total_fully_paid_invoice_amount
FROM
    per_all_people_f p -- Employee details (assuming this view is used for current employee data)
JOIN
    employee_po_creators epc ON p.person_id = epc.employee_id
LEFT JOIN
    Total_Paid_Invoices tpi ON epc.po_header_id = tpi.po_header_id
WHERE
    p.effective_end_date > SYSDATE -- Ensure the employee is currently active (adjust date logic as needed for Fusion)
GROUP BY
    p.first_name,
    p.last_name
ORDER BY
    total_fully_paid_invoice_amount DESC;
```


[FIN Final Output]:
```sql
WITH IT_Equipment_POs AS (
    -- Step 1: Identify all PO Header IDs that contain items categorized as 'IT Equipment'
    SELECT DISTINCT
        pol.po_header_id
    FROM
        po_lines_all pol
    JOIN
        po_items_b item ON pol.po_line_item_id = item.po_line_item_id -- Assuming a link to item details
    WHERE
        -- NOTE: In a real Fusion environment, the category lookup might be more complex, 
        -- but we simulate filtering based on an item attribute/category name.
        item.item_category_name = 'IT Equipment'
),
Employee_PO_Creators AS (
    -- Step 2: Link the POs found above back to the employee who created them
    SELECT DISTINCT
        poh.po_header_id,
        poh.created_by AS employee_person_id
    FROM
        po_headers_all poh
    JOIN
        IT_Equipment_POs iep ON poh.po_header_id = iep.po_header_id
)
SELECT
    p.first_name,
    p.last_name,
    NVL(SUM(ap.invoice_amount), 0) AS total_fully_paid_invoice_amount
FROM
    PER_ALL_PEOPLE_F p -- Employee details (Person table)
JOIN
    Employee_PO_Creators epc ON p.person_id = epc.employee_person_id -- Link employee to PO creator
LEFT JOIN
    po_headers_all poh ON epc.po_header_id = poh.po_header_id
LEFT JOIN
    ap_invoices_all ap ON poh.po_header_id = ap.po_header_id -- Link PO to Invoice
LEFT JOIN
    ap_payments_all pay ON ap.invoice_id = pay.invoice_id AND pay.payment_status = 'PAID' -- Find payments
WHERE
    -- Filter for active employees (assuming a standard status check)
    p.effective_end_date > SYSDATE 
GROUP BY
    p.first_name,
    p.last_name
ORDER BY
    total_fully_paid_invoice_amount DESC;
