-- ========================================================================================================================================
-- sku velocity reclassification — HDS (UPDATED with edp.std_jda.supersession_vw)
-- outputs: dm_supplychain.public.sku_velocity_reclassification_analysis_hds
--          dm_supplychain.public.sku_velocity_reclassification_summary_hds
-- ========================================================================================================================================
-- CHANGE LOG:
--   Updated: October 29, 2025
--   Change: Replaced edp.std_jda.supersession with edp.std_jda.supersession_vw (2 references)
--   Reason: Reduce result set from ~2,500 to 137 records for improved accuracy
--
--   Updated: February 4, 2026
--   Change: Redefined "New" SKU bucket to ONLY include SKUs with NO first receipt date.
--           Previously, SKUs with a first receipt within the last 13 weeks were also classified as New.
--   Reason: Prevent recently-received SKUs from landing in the New SKU bucket when a valid first receipt exists.
-- ========================================================================================================================================

-- ========================================================================================================================================
-- Step 1: Run session parameters
-- ========================================================================================================================================
-- NOTE: This script is runnable without session variables (uses `params` CTE instead).
-- If your team prefers session variables, you may set them here and replace `params.*` references.
--
-- set forecast_weeks  = 13;
-- set weight_dollars  = 0.45;
-- set weight_units    = 0.55;
-- set tier_cutoff_a   = 0.10;
-- set tier_cutoff_b   = 0.30;
-- set tier_cutoff_c   = 0.60;
-- set tier_cutoff_d   = 1.00;


-- ========================================================================================================================================
-- Step 2: Run/Create analysis table (dm_supplychain.public.sku_velocity_reclassification_analysis_hds)
-- ========================================================================================================================================

create or replace table dm_supplychain.public.sku_velocity_reclassification_analysis_hds as (

    with 
    -- Parameters (inline defaults so the script runs even if Step 1 isn't executed)
    params as (
        select
            13::int     as forecast_weeks,
            0.45::float as weight_dollars,
            0.55::float as weight_units,
            0.10::float as tier_cutoff_a,
            0.30::float as tier_cutoff_b,
            0.60::float as tier_cutoff_c,
            1.00::float as tier_cutoff_d
    )

    -- ========== ctes for hds active dc-skus ==========
    ,calendar_info as (
    
        select
            fiscal_week_id
            ,previous_day(current_date, 'Mon') as fscl_wk_bgn_dt
            ,next_day(current_date, 'Sun') as fscl_wk_end_dt
        
        from edp.str_master_data.calendar
        
        where 1=1
            and date_date = current_date()
    
    )
      
    -- ipr team mapping (dedupe to one row per vendor)
    
    ,filtered_ipr_team as (
    
        select
            ltrim(hds_ipr_team.vendor, '0') as vendor
            ,inventory_analyst
            ,manager
            ,row_number() over (partition by vendor order by inventory_analyst) as rn
        
        from dm_supplychain.ia_reporting_data.v_hds_buyer_manager_relationship as hds_ipr_team
        
        qualify rn = 1
    
    )
    
    -- historical unit price (retail) to proxy price if needed
    
    ,unit_price as (
    
        select
            ltrim(vbap.matnr, '0') as matnr
            ,vbak.zzdef_werks as werks
            ,avg(vbap.netpr) as unit_retail_price_dollars
        
        from edp.std_ecc.vbap vbap
        
        left outer join edp.std_ecc.vbak vbak 
            on vbap.vbeln = vbak.vbeln
        
        left outer join dm_supplychain.ia_mpc.mpc mpc 
            on vbap.matnr = mpc.matnr
            and vbak.zzdef_werks = mpc.werks
        
        where ifnull(vbak.auart, '') in ('ZCTR', 'ZGOV', 'ZOR', 'ZPIR', 'ZHP')
            and vbap.zdel_ready = 'Y'
            and vbap.pstyv not in ('ZTAS')
            and ifnull(vbap.abgru, '') in ('', 'ZF', 'ZL')
            and ifnull(vbak.zzdef_werks, '') in (
                select plant_id
                from edp.enh_master_data.plant
                where business_id = 'HDS'
                  and dc_region_id is not null
            )
            and ifnull(vbap.vstel, '') not in ('GA07', 'TX76')
            and mpc.eligible = 'X'
            and try_to_date(vbap.zim_date, 'YYYYMMDD') >= current_date() - 730
        
        group by 1, 2
    
    )
    
    -- merchant cat alignment
    
    ,merchant_category_alignment as (
    
        select distinct
            material_level1_code
            ,material_level2_code
            ,mcat_id
            ,pcat_id
            ,dmm
            ,coalesce(reporting_merchant, sr_merchant, dmm, 'Unknown') as reporting_merchant
        
        from integration.merchandising.cat_merchant_ref
        
        where source = 'HDS'
          and is_current = true
    
    )
    
    ,jda_loc as (
    
        select 
            loc
            ,trim(split_part(descr, '-', 1)) as dc
        
        from dm_supplychain.jda_inbound.jda_loc
    
        where try_cast(loc as number) between 3211 and 3721
    
    )
    
    ,joined as (
    
        select
            i.loc
            ,case
                when i.item = '281259' then 'Kitchen & Bath'
                else m.udc_merch_cat_descr
            end as udc_merch_cat_descr
            ,i.item
            ,case
                when i.item = '281259' then '97853'
                else m.udc_usn_number
            end as udc_usn_number
            ,nvl(m.uom, i.udc_purch_uom) as uom
            ,s.altitem
            ,i.udc_pir_cost
            ,i.udc_velocity_code
    
        from edp.std_jda.skuextract i
    
        left outer join edp.std_jda.dmdunit m
            on i.item = m.dmdunit
        left outer join edp.std_jda.supersession_vw s
            on i.item = s.item
    
    )
    
    -- in-stock weekly cte (last 8 weekly snapshots)
    
    ,m as ( 
    
        select 
            m.item
            ,warehouse_number
            ,sum(instock_local_unit_numerator) as instock_local_unit_numerator_8_weeks
            ,sum(instock_local_unit_denominator) as instock_local_unit_denominator_8_weeks
            ,div0(sum(instock_local_unit_numerator)
            ,sum(instock_local_unit_denominator)) as current_instock_percent_8_weeks
        
        from dm_supplychain.ia_reporting_data.combined_instock_weekly_table m
        
        left outer join edp.str_master_data.calendar c 
            on m.fiscal_week_id = c.fiscal_week_id 
        
        where c.date_date in (
    
                        current_date, current_date - 7, current_date - 14, 
                        current_date - 21, current_date - 28, current_date - 35, 
                        current_date - 42, current_date - 49
                        
                        ) 
            and m.network = 'HDS'
        
        group by all
        
    )
    
    -- 13-week forecast window
    
    ,forecast as (
    
        select 
            skuloc
            ,item
            ,sum(qty) as total_forecasted_qty
        
        from edp.std_jda.dfutoskufcst forecast
        cross join params
        
        left outer join edp.str_master_data.plant p 
            on forecast.skuloc = p.hds_plant_id 
        
        where p.business_id = 'HDS' 
            and (forecast.startdate between current_date and dateadd(week, params.forecast_weeks, current_date)) 
        
        group by all
        
    )
    
     -- soq (fy2025 limited; review annually) -- FOR SAFTEY STOCK CALCULATION
    
    ,filtered_soq as (
    
        select 
            plant
            ,item
            ,orderplace_fy
            ,sum(case when soq is null then 0 else soq end) as total_soq_13_weeks
        
        from dm_supplychain.ia_reporting_data.jda_soq_projections
        
        where orderplace_fy = 'FY2025' 
            and cast(right(orderplace_fw, 2) as int) in (
                                                    
                                                    select 
                                                        week_num 
                                                    
                                                    from (
                                                    
                                                        select 
                                                            cast(right(orderplace_fw, 2) as int) as week_num 
                                                        
                                                        from dm_supplychain.ia_reporting_data.jda_soq_projections 
                                                        
                                                        where orderplace_fy = 'FY2025' 
                                                        
                                                        group by orderplace_fw
                                                        
                                                        order by week_num
                                                        
                                                        limit 13
                                                    )
                                                )
        
        group by all
    
    )
    
    -- high-cube items (business-provided list) // FOR SAFETY STOCK CALCULATION
    
    ,high_cube_items as  ( 
    
        select 
            dmdunit as item 
            ,udc_pir_cost as cost 
            ,udc_product_cat_descr as pcat 
            ,'Y' as high_cube_flg 
        
        from edp.std_jda.dmdunit 
        
        where udc_product_cat_descr in ('Printing Supplies','Paper Product', 
                                        
                                        'Refrigerators','Laundry','Ovens','Water Heaters','Ice Machines','Condensing Units','Safety Storage', 
                                        
                                        'Dishwashers','Shower Doors, Tubs &Enclosures','Banquet Furniture','Trucks & Carts','Compact Appliances','GuestRoom Case Goods&Furniture','Pre-hung Int. Doors', 
                                        
                                        'Wheelchairs & Walkers','Air Handlers, Furnaces & Coils','Pool&Patio Furniture','Shelving & Storage','PTAC & Ductless (Mini Splits)','Hospitality Beds', 
                                        'Exterior Doors','Bellmans Carts & Accessories','Snow & Ice Removal Equipment','Wall Air Conditioners','Microwaves','Bypass Doors','Pillows And Protectors', 
                                        
                                        'Bathroom Vanities','Fab - Countertops','Waste Receptacles And Liners','Ladders & Ladder Acc.','Mattress Pads Covers Toppers','Carts & Receptacles', 
                                        
                                        'Window Air Conditioners','Thru-The-Wall Condensers','Kitchen Cabinets','Brand Standards Linen','Toilets','Towels','Recycling Kits','Lumber', 
                                        
                                        'Blankets','Storage Containers & Shelving','Healthcare Furniture','Portable Air Conditoners','Air Filtration','Fab-Interior Slab Bypass Doors', 
                                        'Foil','Fab - Kitchen Cabinets')  
    
    )

    -- UNIVERSE of ACTIVE DC-SKUS (active + filtering + attributes)
    
    ,all_dc_skus as (
    
        select distinct
            
            'HDS'                                                                           as network
            ,mpc.werks                                                                      as dc
            ,mpc.werks                                                                      as hds_plant_id
    
            ,mpc.mcat_desc                                                                  as mcat
            
            ,ltrim(mpc.matnr, '0')                                                          as item
            ,ltrim(mpc.matnr, '0')                                                          as sku
            ,mpc.matnr                                                                      as material_id
            ,null                                                                           as material_number
            ,null                                                                           as usn
            ,mpc.maktx                                                                      as sku_description
            ,dmdunit.uom                                                                    as dmdunit_uom
            ,case
                when supersession.altitem is not null then 'superseded'
                else 'not superseded'
            end                                                                             as superseded_sku

            -- UPDATED (2026-02-04): "New" means NO first receipt date.
            ,case 
                when frdt.vendor_sku_dc_first_receive_date is null then 'New'
                else 'Not New'
            end                                                                             as sku_status

            ,frdt.vendor_sku_dc_first_receive_date                                          as sku_dc_first_receive_date
            ,up.unit_retail_price_dollars                                                   as sku_retail_price
            ,case
                when sku_extract.udc_pir_cost is null then 0
                else sku_extract.udc_pir_cost
            end                                                                             as cogs
    
            ,m.instock_local_unit_numerator_8_weeks                                         as instock_local_unit_numerator_8_weeks
            ,m.instock_local_unit_denominator_8_weeks                                       as instock_local_unit_denominator_8_weeks
    
            ,div0null(m.instock_local_unit_numerator_8_weeks, m.instock_local_unit_denominator_8_weeks) as current_instock_percent_8_weeks
    
            ,sku_extract.udc_velocity_code                                                  as system_velocity

            -- UPDATED (2026-02-04): Proposed velocity defaults to C only when there is NO first receipt.
            ,case 
                when frdt.vendor_sku_dc_first_receive_date is null then 'C' 
                else 'E' 
            end                                                                             as proposed_velocity

            ,false                                                                          as is_vmi
            
            ,case
                when mpc.zzstocked = 'Y' 
                    and mpc.eligible = 'X' then true
                else false
            end                                                                             as is_active
    
            ,case
                when mpc.werks not in ('GA07', 'MN43') 
                    and left(mpc.werks, 2) <> 'ZZ'
                    and ltrim(mpc.lifnr, '0') not in ('28126', '27191', '28511', '28956', '28302', '')
                    and mpc.mtpos_mara <> 'ZNFS'
                    and mpc.mcat_key not in ('29', '35', '36', '37')
                    and mpc.prodcat_key not in (
                        '103101', '103821', '151150', '151200',
                        '303236', '305518', '305521', '305522', '305524', '305526',
                        '339150', '338403', '338402', '339140', '339120', '339103'
                    ) then false
                else true
            end                                                                             as is_filtered_out
    
            ,case
                when frdt.vendor_sku_dc_first_receive_date is null then 'No First Receipt'
                else 'First Receipt'
            end                                                                             as first_receipt_flg
                
        from dm_supplychain.ia_mpc.mpc mpc
    
        left outer join edp.std_jda.dmdunit dmdunit 
            on ltrim(mpc.matnr, '0') = dmdunit.dmdunit
        
        left outer join integration.finance.ccat_xref_view as ccat
            on case
                when length(mpc.mcat_key) <= 1 then 'HDS|' || lpad(mpc.mcat_key, 2, '0')
                else 'HDS|' || mpc.mcat_key
            end = ccat.mcat_id
        
        inner join edp.enh_master_data.plant as pl
            on pl.hds_plant_id = mpc.werks
            and pl.business_id = 'HDS'
        
        inner join edp.str_master_data.plant
            on mpc.werks = plant.plant_id
        
        left outer join filtered_ipr_team as ipr
            on ltrim(mpc.lifnr, '0') = ipr.vendor
        
        left outer join dm_supplychain.ia_atp.atp as atp
            on mpc.werks = atp.werks
            and mpc.matnr = atp.matnr
        
        left outer join dm_supplychain.inventory_analytics.location_hierarchy as lh
            on mpc.werks = lh.werks
            and lh.business_id = 'HDS'
            and lh.werks <> lh.svcg_linehaul
        
        left outer join dm_supplychain.ia_atp.atp as lh_atp
            on lh.svcg_linehaul = lh_atp.werks
            and mpc.matnr = lh_atp.matnr
        
        left outer join dm_supplychain.ia_in_stock.v_instock_asw_wkly_view as asw
            on mpc.werks = asw.werks
            and ltrim(mpc.matnr, '0') = ltrim(asw.matnr, '0')
        
        left outer join dm_supplychain.pi_demand_planning.pi_catalog
            on ltrim(mpc.matnr, '0') = pi_catalog.material
            and mpc.werks = pi_catalog.dc
        
        inner join dm_supplychain.ia_atlas.atlas
            on mpc.werks = atlas.plant
            and ltrim(mpc.matnr, '0') = ltrim(atlas.material, '0')
        
        left outer join dm_supplychain.ia_atlas.atlas as atlas_lh
            on lh.svcg_linehaul = atlas_lh.plant
            and ltrim(mpc.matnr, '0') = ltrim(atlas_lh.material, '0')
        
        left outer join merchant_category_alignment as mca
            on mpc.prodcat_key = concat(
                ltrim(mca.mcat_id, 'HDS|0'),
                ltrim(mca.pcat_id, 'HDS|')
            )
        
        left outer join unit_price as up
            on mpc.werks = up.werks
            and ltrim(mpc.matnr, '0') = ltrim(up.matnr, '0')
        
        left outer join dm_supplychain.instock.hds_vndr_sku_dc_first_receive_date_tbl as frdt
            on atlas.material = frdt.material_nbr
            and atlas.plant = frdt.plant
            and atlas.vendor = frdt.vendor_nbr
    
        left outer join edp.std_jda.supersession_vw supersession 
            on ltrim(mpc.matnr, '0') = supersession.item
    
        left outer join edp.std_jda.skuextract sku_extract
            on ltrim(mpc.matnr, '0') = sku_extract.item
            and mpc.werks = sku_extract.loc
    
        left outer join m
            on ltrim(mpc.matnr, '0') = m.item
            and mpc.werks = m.warehouse_number        
    
        group by all
        
    )
    
    -- keeping only active & not filtered for velocity reclassification
    
    ,all_active_not_filtered_out_forecasted as (
    
        select
            case
                when forecast.item is not null then 'Forecasted'
                when forecast.item is null then 'Not Forecasted'
                else null
            end as is_forecasted
            
            ,all_dc_skus.network
            ,all_dc_skus.dc
            ,case 
                when all_dc_skus.hds_plant_id is null then p.hds_plant_id 
                else all_dc_skus.hds_plant_id
            end                                                as hds_plant_id            
            
            ,all_dc_skus.mcat
            ,all_dc_skus.item
            ,all_dc_skus.sku
            ,all_dc_skus.material_id
            ,all_dc_skus.usn
            ,all_dc_skus.sku_description
            ,all_dc_skus.dmdunit_uom
            ,all_dc_skus.superseded_sku
            ,all_dc_skus.sku_status
            ,all_dc_skus.sku_dc_first_receive_date
            ,all_dc_skus.sku_retail_price
            ,all_dc_skus.cogs
    
            ,all_dc_skus.instock_local_unit_numerator_8_weeks
            ,all_dc_skus.instock_local_unit_denominator_8_weeks
            ,all_dc_skus.current_instock_percent_8_weeks
            
            ,nvl(forecast.total_forecasted_qty, 0) as total_forecasted_qty
            
            ,all_dc_skus.system_velocity
            
            ,all_dc_skus.is_active
            ,all_dc_skus.is_filtered_out
            ,all_dc_skus.first_receipt_flg
            
        from all_dc_skus
    
        left outer join edp.str_master_data.plant p
            on all_dc_skus.dc = p.plant_id
        
        left outer join forecast
            on (
                case 
                    when all_dc_skus.hds_plant_id is null then p.hds_plant_id 
                    else all_dc_skus.hds_plant_id 
                end
            ) = forecast.skuloc
            and all_dc_skus.item = forecast.item
    
        where all_dc_skus.is_active = true
            and is_filtered_out = false
    
        group by all
        
    )  
      
    -- GROUP 1: forecasted & (not new or new + superseded) → percentile ranks   
    
    ,instock_active_not_filtered_out_forecasted_not_new_superseded_weekly_calc as (
    
        select
            forecast.is_forecasted
            ,forecast.network                             as network
            ,forecast.dc                                  as dc
            ,forecast.hds_plant_id                        as hds_plant_id
            ,forecast.mcat                                as mcat
            ,forecast.item                                as item
            ,case
                when material_id is null then usn
                else material_id
            end                                           as sku
            ,forecast.material_id                         as material_id
            ,forecast.usn                                 as usn
            ,forecast.sku_description                     as sku_description
            ,forecast.dmdunit_uom                         as dmdunit_uom
            ,forecast.superseded_sku                      as superseded_sku
            ,forecast.sku_status                          as sku_status
            ,forecast.sku_dc_first_receive_date           as sku_dc_first_receive_date
            ,forecast.sku_retail_price                    as sku_retail_price
            ,forecast.cogs                                as cogs
    
            ,forecast.is_active
            ,forecast.is_filtered_out
            ,forecast.first_receipt_flg
    
            ,forecast.instock_local_unit_numerator_8_weeks
            ,forecast.instock_local_unit_denominator_8_weeks
            ,forecast.current_instock_percent_8_weeks
            
            ,forecast.total_forecasted_qty                as total_forecasted_qty
            ,forecast.total_forecasted_qty / params.forecast_weeks as weekly_average_forecasted_qty
            ,round(forecast.total_forecasted_qty * forecast.cogs, 2)                                   as total_forecasted_dollars
            ,round((forecast.total_forecasted_qty * forecast.cogs) / params.forecast_weeks, 2)         as weekly_average_forecasted_dollars
            ,forecast.system_velocity                     as system_velocity
            ,(
             params.weight_dollars * (
                COALESCE(forecast.total_forecasted_qty, 0) * forecast.cogs / params.forecast_weeks
             )
            )
            + 
            (
             params.weight_units * (
                COALESCE(forecast.total_forecasted_qty, 0) / params.forecast_weeks
             )
            )                                             as velocity_weight        
        
        from (select * from all_active_not_filtered_out_forecasted where is_forecasted = 'Forecasted') forecast
        cross join params
        
        where (forecast.sku_status != 'New' or forecast.sku_status is null) --- Not New
            or (forecast.sku_status = 'New' and forecast.superseded_sku = 'superseded')
    
    ) 
    
    ,instock_active_not_filtered_out_forecasted_not_new_superseded_ranked_velocity as (
    
        select
            *
            ,round(
                percent_rank() over (
                    partition by dc
                                ,mcat
                        order by velocity_weight desc
                                    )
                , 3)                             as calculated_velocity_percentile
        
        from instock_active_not_filtered_out_forecasted_not_new_superseded_weekly_calc
    
    )
    
    ,instock_active_not_filtered_out_forecasted_not_new_superseded_final_classified as (
            
            select
                v.*
                ,case
                    when cogs is null then 'Missing Data'
                    when calculated_velocity_percentile <= params.tier_cutoff_a then 'A'
                    when calculated_velocity_percentile <= params.tier_cutoff_b then 'B'
                    when calculated_velocity_percentile <= params.tier_cutoff_c then 'C'
                    when calculated_velocity_percentile <= params.tier_cutoff_d then 'D'
                    else null
                end                                                         as new_proposed_velocity
            
            from instock_active_not_filtered_out_forecasted_not_new_superseded_ranked_velocity v
            cross join params
    
    )
    
    -- GROUP 2: forecasted & new & not superseded → force c
    
    ,instock_active_not_filtered_out_forecasted_new_not_superseded_weekly_calc as (
    
        select
            forecast.is_forecasted
            ,forecast.network                       as network
            ,forecast.dc                           as dc
            ,forecast.hds_plant_id                 as hds_plant_id
            ,forecast.mcat                         as mcat
            ,forecast.item                         as item
            ,case
                when material_id is null then usn
                else material_id
            end                                    as sku
            ,forecast.material_id                  as material_id
            ,forecast.usn                          as usn
            ,forecast.sku_description              as sku_description
            ,forecast.dmdunit_uom                  as dmdunit_uom
            ,forecast.superseded_sku               as superseded_sku
            ,forecast.sku_status                   as sku_status
            ,forecast.sku_dc_first_receive_date    as sku_dc_first_receive_date
            ,forecast.sku_retail_price             as sku_retail_price
            ,forecast.cogs                         as cogs
    
            ,forecast.is_active
            ,forecast.is_filtered_out
            ,forecast.first_receipt_flg
    
            ,forecast.instock_local_unit_numerator_8_weeks
            ,forecast.instock_local_unit_denominator_8_weeks
            ,forecast.current_instock_percent_8_weeks
            
            ,forecast.total_forecasted_qty         as total_forecasted_qty
            ,forecast.total_forecasted_qty / params.forecast_weeks           as weekly_average_forecasted_qty
            ,round(forecast.total_forecasted_qty * forecast.cogs, 2)         as total_forecasted_dollars
            ,round((forecast.total_forecasted_qty * forecast.cogs) / params.forecast_weeks, 2) as weekly_average_forecasted_dollars
            ,forecast.system_velocity              as system_velocity
            ,null                                  as velocity_weight
            ,null                                  as calculated_velocity_percentile
        
        from (select * from all_active_not_filtered_out_forecasted where is_forecasted = 'Forecasted') forecast
        cross join params
        
        where forecast.sku_status = 'New' 
            and forecast.superseded_sku = 'not superseded'
    
    )
    
    ,instock_active_not_filtered_out_forecasted_new_not_superseded_final_classified as (
        
        select
            v.*
            ,'C'                as new_proposed_velocity
        
        from instock_active_not_filtered_out_forecasted_new_not_superseded_weekly_calc v
    
    )
    
    -- GROUP 3: not forecasted → new = c, not new = e
    ,instock_active_not_filtered_out_not_forecasted_weekly_calc as (
    
        select
            not_forecast.is_forecasted
            ,not_forecast.network                      as network
            ,not_forecast.dc                           as dc
            ,not_forecast.hds_plant_id                 as hds_plant_id
            ,not_forecast.mcat                         as mcat
            ,not_forecast.item                         as item
            ,case
                when material_id is null then usn
                else material_id
            end                                        as sku
            ,not_forecast.material_id                  as material_id
            ,not_forecast.usn                          as usn
            ,not_forecast.sku_description              as sku_description
            ,not_forecast.dmdunit_uom                  as dmdunit_uom
            ,not_forecast.superseded_sku               as superseded_sku
            ,not_forecast.sku_status                   as sku_status
            ,not_forecast.sku_dc_first_receive_date    as sku_dc_first_receive_date
            ,not_forecast.sku_retail_price             as sku_retail_price
            ,not_forecast.cogs                         as cogs
    
            ,not_forecast.is_active
            ,not_forecast.is_filtered_out
            ,not_forecast.first_receipt_flg
    
            ,not_forecast.instock_local_unit_numerator_8_weeks
            ,not_forecast.instock_local_unit_denominator_8_weeks
            ,not_forecast.current_instock_percent_8_weeks
            
            ,not_forecast.total_forecasted_qty     as total_forecasted_qty
            ,not_forecast.total_forecasted_qty / params.forecast_weeks      as weekly_average_forecasted_qty
            ,round(not_forecast.total_forecasted_qty * not_forecast.cogs, 2) as total_forecasted_dollars
            ,round((not_forecast.total_forecasted_qty * not_forecast.cogs) / params.forecast_weeks, 2) as weekly_average_forecasted_dollars
            ,not_forecast.system_velocity          as system_velocity
            ,null                                  as velocity_weight
            ,null                                  as calculated_velocity_percentile
        
        from all_active_not_filtered_out_forecasted not_forecast
        cross join params
        
        where is_forecasted = 'Not Forecasted'
            
    )
    
    ,instock_active_not_filtered_out_not_forecasted_final_classified as (
        
        select
            v.*
            ,case
                when v.sku_status = 'New' then 'C'
                when v.sku_status = 'Not New' then 'E'
                else null
            end as new_proposed_velocity
        
        from instock_active_not_filtered_out_not_forecasted_weekly_calc v
    
    )

    -- UNIONING/JOINING ALL 3 GROUPS FOR FULL VELOCITY RECLASSIFICATION FOR ALL HDP ACTIVE SKUS
    
    ,instock_active_not_filtered_out_forecasted_final_classified as (
    
        select 
            *
        from instock_active_not_filtered_out_forecasted_not_new_superseded_final_classified
        
        union all
        
        select
            *
        from instock_active_not_filtered_out_forecasted_new_not_superseded_final_classified
    
        union all
    
        select
            *
        from instock_active_not_filtered_out_not_forecasted_final_classified
        order by
            dc
            ,mcat
            ,new_proposed_velocity
            ,velocity_weight desc
    
    )
    
    -- sscov mapping (current vs proposed) //  FOR SAFETY STOCK CALCULATION
    
    ,sscov_weeks as (
        
        select 
            v.*
            ,h.pcat
            ,case 
                when h.high_cube_flg = 'Y' then 'High' 
                else 'Low' 
            end as cube
            ,i.import_flag
            
            -- current sscov weeks
            ,case 
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.system_velocity = 'A' then 4
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.system_velocity = 'B' then 4
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.system_velocity = 'C' then 3
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.system_velocity in ('D','E') then 3
            
                when i.import_flag = 'Domestic' and h.high_cube_flg = 'Y' and v.system_velocity in ('A','B','C','D') then 3
                when i.import_flag = 'Domestic' and h.high_cube_flg = 'Y' and v.system_velocity = 'E' then 0
            
                when i.import_flag = 'Import' and h.high_cube_flg is null and v.system_velocity in ('A','B') then 6
                when i.import_flag = 'Import' and h.high_cube_flg is null and v.system_velocity = 'C' then 4
                when i.import_flag = 'Import' and h.high_cube_flg is null and v.system_velocity in ('D','E') then 3
            
                when i.import_flag = 'Import' and h.high_cube_flg = 'Y' and v.system_velocity in ('A','B') then 4
                when i.import_flag = 'Import' and h.high_cube_flg = 'Y' and v.system_velocity = 'C' then 3
                when i.import_flag = 'Import' and h.high_cube_flg = 'Y' and v.system_velocity in ('D','E') then 3
            
                else 0
            end as current_sscov
            
            -- proposed sscov weeks
            ,case 
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.new_proposed_velocity = 'A' then 4
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.new_proposed_velocity = 'B' then 4
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.new_proposed_velocity = 'C' then 3
                when i.import_flag = 'Domestic' and h.high_cube_flg is null and v.new_proposed_velocity in ('D','E') then 3
            
                when i.import_flag = 'Domestic' and h.high_cube_flg = 'Y' and v.new_proposed_velocity in ('A','B','C','D') then 3
                when i.import_flag = 'Domestic' and h.high_cube_flg = 'Y' and v.new_proposed_velocity = 'E' then 0
            
                when i.import_flag = 'Import' and h.high_cube_flg is null and v.new_proposed_velocity in ('A','B') then 6
                when i.import_flag = 'Import' and h.high_cube_flg is null and v.new_proposed_velocity = 'C' then 4
                when i.import_flag = 'Import' and h.high_cube_flg is null and v.new_proposed_velocity in ('D','E') then 3
            
                when i.import_flag = 'Import' and h.high_cube_flg = 'Y' and v.new_proposed_velocity in ('A','B') then 4
                when i.import_flag = 'Import' and h.high_cube_flg = 'Y' and v.new_proposed_velocity = 'C' then 3
                when i.import_flag = 'Import' and h.high_cube_flg = 'Y' and v.new_proposed_velocity in ('D','E') then 3
            
                else 0
            end as proposed_sscov
    
        from instock_active_not_filtered_out_forecasted_final_classified v
        
        left outer join (
        
            select 
                dmdunit.*
                
                ,case 
                    when udc_import_type = '1' then 'Import' 
                    when udc_import_type is null then 'Domestic' 
                    else 'Domestic' 
                end as import_flag 
                    
                    
                from edp.std_jda.dmdunit
            
            ) i 
            on v.item = i.dmdunit
        
        left outer join high_cube_items h 
            on v.item = h.item 
    
    )
    
    -- SAFETY STOCK CALCULATION 
    
    ,safety_stock_calc as (
        
        select 
            sscov_weeks.*
            ,nvl(soq.total_soq_13_weeks, 0) as current_total_soq_13_weeks      
            
            ,round(
                sscov_weeks.weekly_average_forecasted_qty * sscov_weeks.current_sscov, 2
                ) as current_safety_stock
            
            ,round(
                sscov_weeks.weekly_average_forecasted_qty * sscov_weeks.proposed_sscov, 2
                ) as proposed_safety_stock
            
            ,round(
                sscov_weeks.weekly_average_forecasted_qty * (sscov_weeks.proposed_sscov - sscov_weeks.current_sscov), 2
                ) as safety_stock_change
            ,round(
                (sscov_weeks.weekly_average_forecasted_qty * (sscov_weeks.proposed_sscov - sscov_weeks.current_sscov)) * cogs, 2
                ) as safety_stock_change_dollars
           
           ,case
                when sscov_weeks.system_velocity is null or sscov_weeks.new_proposed_velocity is null then 'Unclassified'
                when sscov_weeks.system_velocity = sscov_weeks.new_proposed_velocity then 'Match'
                when sscov_weeks.system_velocity < sscov_weeks.new_proposed_velocity then 'Demotion'
                when sscov_weeks.system_velocity > sscov_weeks.new_proposed_velocity then 'Promotion'
            end as velocity_change_class
    
        from sscov_weeks
        
        left join edp.str_master_data.plant plant 
            on sscov_weeks.dc = plant.plant_id
        
        left join filtered_soq soq 
            on plant.hds_plant_id = soq.plant and sscov_weeks.item = soq.item
    
    )

    -- FINAL ANALYSIS OUTPUT
    
    ,analysis_output as (
    
        select 
            -- Table last create date
            current_date as table_created_date
            
            -- SKU & Hierarchy Info
            ,network
            ,dc
            ,hds_plant_id as jda_loc
            ,mcat
            ,item as jda_item
            ,material_id
            ,sku_description
            ,dmdunit_uom as jda_uom
        
            -- Flags & Status
            ,is_forecasted
            ,is_active
            ,is_filtered_out
            ,first_receipt_flg
            ,sku_status
            ,superseded_sku
        
            -- Inventory Metrics
            ,instock_local_unit_numerator_8_weeks
            ,instock_local_unit_denominator_8_weeks
            ,round(current_instock_percent_8_weeks, 2) as current_instock_percent_8_weeks
            
            -- Forecasting & Velocity
            ,total_forecasted_qty
            ,weekly_average_forecasted_qty
            ,total_forecasted_dollars
            ,weekly_average_forecasted_dollars
            ,velocity_weight
            ,calculated_velocity_percentile
            ,system_velocity
            ,new_proposed_velocity
            ,case
                when new_proposed_velocity = 'A' then 99.2
                when new_proposed_velocity = 'B' then 99.0
                when new_proposed_velocity = 'C' then 98.0
                when new_proposed_velocity = 'D' then 85.0
                when new_proposed_velocity = 'E' then 80.0
                else 99999
            end as service_level
            ,velocity_change_class
            ,case
                when 
                    is_forecasted = 'Forecasted' and sku_status = 'New' and superseded_sku = 'superseded'
                    or (is_forecasted = 'Forecasted' and sku_status = 'Not New')
                then 'Velocity Tier A-D Driver: Forecasted/Core/Superseded'
            
                when is_forecasted = 'Forecasted' and sku_status = 'New' and superseded_sku = 'not superseded'
                then 'Velocity Tier C Driver: Forecasted/New/Not Superseded'
            
                when is_forecasted = 'Not Forecasted' and sku_status = 'New'
                then 'Velocity Tier C Driver: Not Forecasted/New'
            
                when is_forecasted = 'Not Forecasted' and sku_status = 'Not New'
                then 'Velocity Tier E Driver: Not Forecasted/Not New'
            
                else 'Other or Unclassified'
            end as velocity_reason
    
            -- SSCOV Metadata
            ,pcat
            ,cube
            ,import_flag
            ,current_sscov
            ,proposed_sscov
        
            -- Safety Stock & Financial Impact
            ,current_total_soq_13_weeks
            ,current_safety_stock
            ,proposed_safety_stock
            ,safety_stock_change
            ,safety_stock_change_dollars
        
            -- Cost & Pricing
            ,sku_retail_price
            ,cogs
        
        from safety_stock_calc
        
        order by
            network
            ,dc
            ,mcat
            ,new_proposed_velocity
            ,velocity_weight desc
    
    )
    
    select * from analysis_output

);

-- ========================================================================================================================================
-- Step 3: Run newly created table to confirm update
-- ========================================================================================================================================

select * from dm_supplychain.public.sku_velocity_reclassification_analysis_hds;

-- ========================================================================================================================================
-- Step 4: Create table that outputs only Velocity changes
-- ========================================================================================================================================

create or replace table dm_supplychain.public.sku_velocity_reclassification_summary_hds as (

    select 
        current_date as table_created_date
        ,jda_item
        ,jda_loc
        ,new_proposed_velocity as proposed_velocity
        ,new_proposed_velocity as proposed_velocity_ -- duplicate column needed for uploading process
        ,service_level
        ,system_velocity as sap_velocity
        ,velocity_reason
    
    from dm_supplychain.public.sku_velocity_reclassification_analysis_hds
    
    where new_proposed_velocity != system_velocity

)
;

-- ========================================================================================================================================
-- Step 5: Run queries separately that creates an individual output/file for each proposed velocity (A-E)
-- ========================================================================================================================================

select
    jda_item
    ,jda_loc
    ,proposed_velocity
    ,proposed_velocity_ 
    ,service_level 
    ,sap_velocity
    ,velocity_reason

from dm_supplychain.public.sku_velocity_reclassification_summary_hds

where
  proposed_velocity IN ('A', 'B', 'C', 'D', 'E')
;

-- ========================================================================================================================================
-- Step 6: ALL DONE!!! :)
-- ========================================================================================================================================
