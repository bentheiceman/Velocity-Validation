-- ========================================================================================================================================
-- sku velocity reclassification — HDP (UPDATED with edp.std_jda.supersession_vw)
-- outputs: dm_supplychain.public.sku_velocity_reclassification_analysis_hdp
--          dm_supplychain.public.sku_velocity_reclassification_summary_hdp
-- ========================================================================================================================================
-- CHANGE LOG:
--   Updated: October 29, 2025
--   Change: Replaced edp.std_jda.supersession with edp.std_jda.supersession_vw
--   Reason: Reduce result set from ~2,500 to 137 records for improved accuracy
-- ========================================================================================================================================
-- process overview:
--   Step 1: Run session parameters (forecast horizon, weights, percentile cutoffs).
--   Step 2: Create full analysis table → dm_supplychain.public.sku_velocity_reclassification_analysis_hdp.
--   Step 3: Validate the analysis output (check `table_created_date` and sampled rows).
--   Step 4: Create change-only summary table → dm_supplychain.public.sku_velocity_reclassification_summary_hdp.
--   Step 5: Generate/export five separate outputs (A–E) by filtering the summary table.
--   Step 6: Wrap-up.


-- ========================================================================================================================================
-- Step 1: Run session parameters
-- ========================================================================================================================================
set forecast_weeks  = 13;
set weight_dollars  = 0.45;
set weight_units    = 0.55;
set tier_cutoff_a   = 0.10;
set tier_cutoff_b   = 0.30;
set tier_cutoff_c   = 0.60;
set tier_cutoff_d   = 1.00;


-- ========================================================================================================================================
-- Step 2: Run/Create analysis table (dm_supplychain.public.sku_velocity_reclassification_analysis_hdp)
-- ========================================================================================================================================

create or replace table dm_supplychain.public.sku_velocity_reclassification_analysis_hdp as (

    with
    -- ========== ctes for hdp active dc-skus ==========
    linehaul_mapping as (

        select distinct
            e3_item.iitem as usn
            ,whse.warehouse_num as destination_plant
            ,case
                when e3_item.isupv like '%con%'
                     or e3_item.isupv in ('8000105C', '8000143C', '8000072C', '8000059C') then 'CON'
                when e3_item.isupv is null or e3_item.isupv = '' or e3_item.isupv like '%SV%' then 'DIR'
                when startswith(upper(e3_item.isupv), 'MT') then split_part(upper(e3_item.isupv), 'T', 2)
                when ltrim(upper(e3_item.isupv), 'WX0') <> e3_item.isupv then ltrim(split_part(upper(e3_item.isupv), 'T', 1), 'WX0')
                when e3_item.isupv = 'W140TW13' then '140'
                when e3_item.isupv = 'W129T180' then '129'
                else 'DIR'
            end as source_plant

        from hdpro_stg.stg.raw_e3_item as e3_item

        inner join dm_supplychain.pro_ops.v_lkup_warehouse as whse
            on e3_item.iwhse = whse.warehouse_num_e3

        where e3_item.iactv = 0
          and source_plant <> destination_plant

    )

    ,unit_price_by_warehouse as (

        select
            fs.sku_id
            ,usn
            ,shipping_warehouse_id
            ,div0(sum(net_amt), sum(shipped_qty)) as unit_retail_price_dollars

        from hdpro_dw.sales.fact_sales as fs

        left join hdpro_ods.ods.sku as s
            on s.sku_id = fs.sku_id

        where fs.sku_id <> 0
            and fs.create_date >= current_date() - 1095
            and fs.shipping_warehouse_id <> 0

        group by
            fs.sku_id
            ,s.usn
            ,fs.shipping_warehouse_id

    )

    ,jda_loc as (

        select
            loc,
            trim(split_part(descr, '-', 1)) as dc

        from DM_SUPPLYCHAIN.JDA_INBOUND.JDA_LOC

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
            m.sku_id
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
            and m.network = 'HDP'

        group by all

    )

    -- 13-week forecast window (based on param)

    ,forecast as (

        select
            skuloc
            ,item
            ,sum(qty) as total_forecasted_qty

        from edp.std_jda.dfutoskufcst forecast

        left outer join edp.str_master_data.plant p
            on forecast.skuloc = p.hds_plant_id

        where p.business_id = 'HDP'
            and (forecast.startdate between current_date and dateadd(week, $forecast_weeks, current_date))

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
            'HDP'                                                           as network
            ,siw.warehouse_number                                           as dc
            ,nvl(warehouse_dim.hds_plant_id, jda_loc.loc)                   as hds_plant_id

            ,joined.udc_merch_cat_descr                                     as mcat

            ,joined.item                                                    as item
            ,siw.usn                                                        as sku
            ,null                                                           as material_id
            ,null                                                           as material_number
            ,siw.usn                                                        as usn
            ,siw.item_description                                           as sku_description
            ,joined.uom                                                     as dmdunit_uom
            ,case
                when joined.altitem is not null then 'superseded'
                else 'not superseded'
            end                                                             as superseded_sku

            ,case
                when frdt.first_receive_date is null
                    or frdt.first_receive_date >= dateadd(week, -13, current_date) then 'New'
                else 'Not New'
            end                                                             as sku_status
            ,frdt.first_receive_date                                        as sku_dc_first_receive_date

            ,unit_price.unit_retail_price_dollars                           as sku_retail_price
            ,case
                when joined.udc_pir_cost is null then 0
                else joined.udc_pir_cost
            end                                                             as cogs

            ,m.instock_local_unit_numerator_8_weeks                         as instock_local_unit_numerator_8_weeks
            ,m.instock_local_unit_denominator_8_weeks                       as instock_local_unit_denominator_8_weeks

            ,div0null(m.instock_local_unit_numerator_8_weeks, m.instock_local_unit_denominator_8_weeks) as current_instock_percent_8_weeks


            ,joined.udc_velocity_code                                       as system_velocity
            ,case
                when frdt.first_receive_date is null
                    or frdt.first_receive_date >= dateadd(week, -13, current_date) then 'C'
                else 'E'
            end                                                             as proposed_velocity


            ,case
                when dw.region_name in ('VMI','Unknown Region') then true
                else false
            end                                                             as is_vmi

            ,case
                when (s.sku_id <> 0
                    and upper(siw.ipr_category) = 'REPLENISHED') then true
                else false
            end                                                             as is_active

            ,case
                when siw.warehouse_number not in (
                    '701','702','226','229','235','177','304','372',
                    '49','295','409','371','107','354'
                )
                    and warehouse.is_open_for_operations = 1 then false
                else true
            end                                                             as is_filtered_out

            ,case
                when frdt.first_receive_date is null then 'No First Receipt'
                else 'First Receipt'
            end                                                             as first_receipt_flg

        from dm_supplychain.pro_inventory_analytics.report_assortment_daily_sibw_ex as siw

        inner join edp.str_master_data.calendar
            on calendar.date_date = current_date()

        inner join dm_supplychain.pro_inventory_analytics.master_inventory_table_current as mit
            on mit.usn = siw.usn
            and mit.warehouse_number = siw.warehouse_number

        left join dm_supplychain.ia_reporting_data.storage_type_ice_report
            on siw.usn = storage_type_ice_report."usn"
            and siw.warehouse_number = storage_type_ice_report."warehouse_num"

        left join linehaul_mapping as lh
            on siw.warehouse_number = lh.destination_plant
            and siw.usn = lh.usn

        left join dm_supplychain.pro_inventory_analytics.report_assortment_daily_sibw_ex as siwlh
            on siwlh.warehouse_number = lh.source_plant
            and siwlh.usn = siw.usn

        inner join hdpro_dw.common.dim_warehouse
            on siw.warehouse_number = dim_warehouse.warehouse_num

        inner join hdpro_ods.ods.warehouse
            on warehouse.warehouse_id = dim_warehouse.warehouse_id

        inner join hdpro_ods.ods.sku as s
            on siw.usn = s.usn

        inner join hdpro_dw.common.dim_taxonomy as t
            on t.taxonomy_id = s.taxonomy_id

        left join integration.finance.ccat_xref_view as ccat
            on ('PRO' || '|' || t.taxonomy_level_1_id::string) = ccat.mcat_id

        left join integration.merchandising.cat_merchant_ref as merchant
            on trim(upper(t.taxonomy_level_2_id)) = trim(upper(merchant.material_level2_code))
            and merchant.source = 'HDP'
            and is_current = true

        left join unit_price_by_warehouse as unit_price
            on siw.usn = unit_price.usn
            and dim_warehouse.warehouse_id = unit_price.shipping_warehouse_id

        left outer join dm_supplychain.ia_reporting_data.v_hdp_first_receive_date as frdt
            on frdt.usn = siw.usn
            and frdt.warehouse_num = siw.warehouse_number

        left join dm_supplychain.pro_ops.v_lkup_dim_warehouse dw
            on dw.warehouse_id = dim_warehouse.warehouse_id
            and dw.is_open_for_operations = true

        left outer join (with vmi as (

                            select
                                substr(name1,2,3)   as vmi1
                                ,werks              as werks

                            from edp.std_s4.t001w

                        )

                        select
                            trim(vmi1,'_')          as warehouse_num
                            ,werks                  as hds_plant_id

                        from vmi

                        ) warehouse_dim
            on dw.warehouse_num = warehouse_dim.warehouse_num

        left outer join jda_loc
            on siw.warehouse_number = jda_loc.dc

        left outer join m
            on s.sku_id = m.sku_id
            and siw.warehouse_number = m.warehouse_number

        left outer join joined
            on siw.usn = joined.udc_usn_number
            and nvl(warehouse_dim.hds_plant_id, jda_loc.loc) = joined.loc

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
            ,forecast.total_forecasted_qty
                /
            $forecast_weeks                               as weekly_average_forecasted_qty
            ,round(forecast.total_forecasted_qty
                    *
                   forecast.cogs
                   , 2)                                   as total_forecasted_dollars
            ,round(
                (forecast.total_forecasted_qty
                    *
                  forecast.cogs)
                /
                $forecast_weeks
                 , 2)                                     as weekly_average_forecasted_dollars
            ,forecast.system_velocity                     as system_velocity
            ,(
             $weight_dollars * (
                COALESCE(forecast.total_forecasted_qty, 0) * forecast.cogs / $forecast_weeks
             )
            )
            +
            (
             $weight_units * (
                COALESCE(forecast.total_forecasted_qty, 0) / $forecast_weeks
             )
            )                                             as velocity_weight

        from (select * from all_active_not_filtered_out_forecasted where is_forecasted = 'Forecasted') forecast

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
                    when calculated_velocity_percentile <= $tier_cutoff_a then 'A'
                    when calculated_velocity_percentile <= $tier_cutoff_b then 'B'
                    when calculated_velocity_percentile <= $tier_cutoff_c then 'C'
                    when calculated_velocity_percentile <= $tier_cutoff_d then 'D'
                    else null
                end                                                         as new_proposed_velocity

            from instock_active_not_filtered_out_forecasted_not_new_superseded_ranked_velocity v

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
            ,forecast.total_forecasted_qty
                /
            $forecast_weeks                        as weekly_average_forecasted_qty
            ,round(forecast.total_forecasted_qty
                    *
                   forecast.cogs
                   , 2)                            as total_forecasted_dollars
            ,round(
                (forecast.total_forecasted_qty
                    *
                  forecast.cogs)
                /
                $forecast_weeks
                 , 2)                              as weekly_average_forecasted_dollars
            ,forecast.system_velocity              as system_velocity
            ,null                                  as velocity_weight
            ,null                                  as calculated_velocity_percentile

        from (select * from all_active_not_filtered_out_forecasted where is_forecasted = 'Forecasted') forecast

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
            ,not_forecast.total_forecasted_qty
                /
            $forecast_weeks                        as weekly_average_forecasted_qty
            ,round(not_forecast.total_forecasted_qty
                    *
                   not_forecast.cogs
                   , 2)                            as total_forecasted_dollars
            ,round(
                (not_forecast.total_forecasted_qty
                    *
                  not_forecast.cogs)
                /
                $forecast_weeks
                 , 2)                              as weekly_average_forecasted_dollars
            ,not_forecast.system_velocity          as system_velocity
            ,null                                  as velocity_weight
            ,null                                  as calculated_velocity_percentile

        from all_active_not_filtered_out_forecasted not_forecast

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
        from instock_active_not_filtered_out_forecasted_not_new_superseded_final_classified // Percentiled Velocities for: In-Stock Active/Not Filtered Out, Forecasted, Not New Skus & Superseded

        union all

        select
            *
        from instock_active_not_filtered_out_forecasted_new_not_superseded_final_classified // Defaulted C Velocities for: In-Stock Active/Not Filtered Out, Forecasted, New Skus Status & Not Supereded

        union all

        select
            *
        from instock_active_not_filtered_out_not_forecasted_final_classified // Defaulted E and C Velocities for: In-Stock Active/Not Filtered Out, Not Forecasted
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
            -- Tabel last create date
            current_date as table_created_date

            -- SKU & Hierarchy Info
            ,network
            ,dc
            ,hds_plant_id as jda_loc
            ,mcat
            ,item as jda_item
            ,usn
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

            -- Cost & Pricing Data
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
-- Step 3: Run newly created table to confirm update (looking at date under table_created_date )
-- ========================================================================================================================================

select * from dm_supplychain.public.sku_velocity_reclassification_analysis_hdp;

-- ========================================================================================================================================
-- Step 4: Create table that outputs only Velocity changes
-- ========================================================================================================================================
create or replace table dm_supplychain.public.sku_velocity_reclassification_summary_hdp as (

    select
        current_date as table_created_date
        ,jda_item
        ,jda_loc
        ,usn
        ,dc
        ,new_proposed_velocity as proposed_velocity
        ,new_proposed_velocity as proposed_velocity_ -- duplicate column needed for uploading process
        ,service_level -- defined by upper management
        ,system_velocity as sap_velocity
        ,velocity_reason

    from dm_supplychain.public.sku_velocity_reclassification_analysis_hdp

    where new_proposed_velocity != system_velocity

)
;

-- ========================================================================================================================================
-- Step 5: Run queries separately that creates an individual output/file for each proposed velocity (A-E) -- YOU WILL QUERY/OUTPUT 5 FILES
-- -- This is a preference of submission for Jennifer Smith to upload these changes to the system.
-- -- You will send these files to JS in an email.
-- ========================================================================================================================================

select
    jda_item
    ,jda_loc
    ,usn
    ,dc
    ,proposed_velocity
    ,proposed_velocity_
    ,service_level
    ,sap_velocity
    ,velocity_reason

from dm_supplychain.public.sku_velocity_reclassification_summary_hdp

where
  proposed_velocity IN ('A', 'B', 'C', 'D', 'E')
;

-- ========================================================================================================================================
-- Step 6: ALL DONE!!! :)
-- ========================================================================================================================================
