-- =====================================================================
-- 2026年分县区人才队伍月报 · 逐月填报系统（v3 - 整合完美版）
-- 在 Supabase Dashboard → SQL Editor → New query 整段执行
-- =====================================================================
-- 【脚本说明】
-- 1. 本脚本会重建所有表结构，并配置 RLS、审计触发器等。
-- 2. 解决了之前 UUID 外键报错问题，采用"智能邮箱匹配"绑定账号。
-- 3. 兼容了 v2 表的拆分字段，并默认将培训总数导入到"企业职工"字段。
-- 4. v3 新增：regions 表按年设定目标（year 列），支持跨年。
-- =====================================================================

-- ========== 0. 清理旧结构 ==========
-- 注意：如果你现在的库里有重要数据，请将下面四行注释掉（或先备份）
drop table if exists public.fill_logs cascade;
drop table if exists public.monthly_reports cascade;
drop table if exists public.profiles cascade;
drop table if exists public.regions cascade;


-- ========== 1. regions：县区目标值（按年设定） ==========
-- 作用：存放 12 个填报单位的年度总目标，系统累计进度都基于此表计算。
create table public.regions (
  year           int not null,               -- 目标年份，如 2026
  region         text not null,
  peixun_target  int not null default 0,     -- 全年培训目标任务
  jineng_target  int not null default 0,     -- 全年技能人才目标任务
  gjg_target     int not null default 0,     -- 全年高级工以上目标任务
  primary key (year, region)
);


-- ========== 2. monthly_reports：每县区每月一条，存当月新增 ==========
-- 作用：按"月"记录各个县区的具体填报数据，前端通过 SUM() 累加出年度进度。
create table public.monthly_reports (
  id                   uuid primary key default gen_random_uuid(), -- 唯一记录 ID
  report_month         text not null,            -- 所属月份（如 '2026-09'）
  region               text not null,            -- 县区名（无外键，按年目标另行关联）
  peixun_zd_biye_c     int not null default 0,   -- 当月新增·培训-重点-毕业年度高校毕业生
  peixun_zd_chuzhong_c int not null default 0,   -- 当月新增·培训-重点-城乡未升学应届初高中
  peixun_zd_nongcun_c  int not null default 0,   -- 当月新增·培训-重点-农村转移就业劳动力
  peixun_zd_tuopin_c   int not null default 0,   -- 当月新增·培训-重点-脱贫劳动力
  peixun_zd_kunnan_c   int not null default 0,   -- 当月新增·培训-重点-就业困难人员
  peixun_zd_shiye_c    int not null default 0,   -- 当月新增·培训-重点-失业人员
  peixun_qiye_c        int not null default 0,   -- 当月新增·培训-企业职工
  peixun_chuangye_c    int not null default 0,   -- 当月新增·培训-创业培训
  peixun_baihang_c     int not null default 0,   -- 当月新增·培训-百行百业（仅市本级）
  peixun_gongyi_c      int not null default 0,   -- 当月新增·培训-公益类培训
  jineng_sheng_c       int not null default 0,   -- 当月新增·技能人才省级
  jineng_shi_c         int not null default 0,   -- 当月新增·技能人才市级
  gjg_sheng_c          int not null default 0,   -- 当月新增·高级工省级
  gjg_shi_c            int not null default 0,   -- 当月新增·高级工市级
  updated_by           uuid references auth.users(id), -- 最后修改该行数据的用户 ID
  updated_at           timestamptz default now(),      -- 最后修改时间
  unique (region, report_month)                  -- 唯一约束：一个县区一个月只能有一条记录
);


-- ========== 3. fill_logs：修改审计表 ==========
-- 作用：由下方的触发器自动写入，记录每一次数据的修改历史（防扯皮神器）。
create table public.fill_logs (
  id           bigint generated always as identity primary key, -- 自增主键
  report_month text not null,              -- 被修改的月份
  region       text not null,              -- 被修改的县区
  field        text not null,              -- 被修改的字段名（如 peixun_qiye_c）
  old_value    int,                        -- 修改前的值
  new_value    int,                        -- 修改后的值
  filled_by    uuid references auth.users(id), -- 操作人 ID
  filled_at    timestamptz default now()   -- 操作时间
);
-- 创建索引：加快前端按县区和月份查询审计日志的速度
create index if not exists idx_fill_logs_region_month on public.fill_logs(region, report_month);


-- ========== 4. profiles：账号 → 县区 / 管理员 ==========
-- 作用：建立 Supabase 登录账号（auth.users）与业务县区的绑定关系。
create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade, -- 绑定 Auth 用户，级联删除
  region     text,                         -- 所属县区名；管理员此项为 NULL
  is_admin   boolean not null default false, -- 是否是管理员（true 可看所有数据）
  created_at timestamptz default now()
);


-- ========== 5. 行级安全策略（RLS） ==========
-- 作用：开启后，普通用户只能操作自己县区的数据，防止越权。管理员全开。
alter table public.regions         enable row level security;
alter table public.monthly_reports enable row level security;
alter table public.fill_logs       enable row level security;
alter table public.profiles        enable row level security;

-- regions 表：所有登录用户都可以读取目标值（但只能管理员修改，见下方的触发器保护）
create policy "regions_select_auth" on public.regions
  for select to authenticated using (true);

-- regions 表：仅管理员可插入新年度目标
create policy "regions_insert_admin" on public.regions
  for insert to authenticated
  with check ((select is_admin from public.profiles where id = auth.uid()) = true);

-- regions 表：仅管理员可修改目标值
create policy "regions_update_admin" on public.regions
  for update to authenticated
  using ((select is_admin from public.profiles where id = auth.uid()) = true)
  with check ((select is_admin from public.profiles where id = auth.uid()) = true);

-- monthly_reports 表：只能读取自己县区的，或者是管理员读取所有
create policy "monthly_select_own_or_admin" on public.monthly_reports
  for select to authenticated
  using ((select is_admin from public.profiles where id = auth.uid()) = true or region = (select region from public.profiles where id = auth.uid()));

-- monthly_reports 表：只能插入自己县区的数据
create policy "monthly_insert_own" on public.monthly_reports
  for insert to authenticated
  with check ( region = (select region from public.profiles where id = auth.uid()) );

-- monthly_reports 表：只能更新自己县区的，或者管理员更新
create policy "monthly_update_own_or_admin" on public.monthly_reports
  for update to authenticated
  using ((select is_admin from public.profiles where id = auth.uid()) = true or region = (select region from public.profiles where id = auth.uid()))
  with check ((select is_admin from public.profiles where id = auth.uid()) = true or region = (select region from public.profiles where id = auth.uid()));

-- fill_logs 表：审计日志，只能看自己县区的，管理员看所有
create policy "fill_logs_select_own_or_admin" on public.fill_logs
  for select to authenticated
  using ((select is_admin from public.profiles where id = auth.uid()) = true or region = (select region from public.profiles where id = auth.uid()));

-- profiles 表：普通用户登录后只能查询自己的绑定关系
create policy "profiles_select_own" on public.profiles
  for select to authenticated using (id = auth.uid());


-- ========== 6. 目标列保护（触发器） ==========
-- 作用：虽然 RLS 允许普通用户读 regions 表，但绝对不允许他们修改目标值，只有管理员能改。
create or replace function public.protect_region_target()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- 检查当前操作人是否为管理员
  if coalesce((select is_admin from public.profiles where id = auth.uid()), false) = false then
    -- 如果不是管理员，且目标值发生了变化，则抛出异常并阻止更新
    if new.peixun_target is distinct from old.peixun_target
       or new.jineng_target is distinct from old.jineng_target
       or new.gjg_target  is distinct from old.gjg_target
       or new.year is distinct from old.year then
      raise exception '非管理员不可修改目标任务';
    end if;
  end if;
  return new;
end; $$;
-- 绑定触发器到 regions 表
drop trigger if exists trg_protect_region_target on public.regions;
create trigger trg_protect_region_target before update on public.regions for each row execute function public.protect_region_target();


-- ========== 7. 修改审计触发器 ==========
-- 作用：前端修改 monthly_reports 时，自动对比新旧值，写入 fill_logs。

-- 7.1 更新时触发（对比新旧值）
create or replace function public.record_fill_log()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.peixun_zd_biye_c is distinct from old.peixun_zd_biye_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_zd_biye_c', old.peixun_zd_biye_c, new.peixun_zd_biye_c, new.updated_by, new.updated_at); end if;
  if new.peixun_zd_chuzhong_c is distinct from old.peixun_zd_chuzhong_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_zd_chuzhong_c', old.peixun_zd_chuzhong_c, new.peixun_zd_chuzhong_c, new.updated_by, new.updated_at); end if;
  if new.peixun_zd_nongcun_c is distinct from old.peixun_zd_nongcun_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_zd_nongcun_c', old.peixun_zd_nongcun_c, new.peixun_zd_nongcun_c, new.updated_by, new.updated_at); end if;
  if new.peixun_zd_tuopin_c is distinct from old.peixun_zd_tuopin_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_zd_tuopin_c', old.peixun_zd_tuopin_c, new.peixun_zd_tuopin_c, new.updated_by, new.updated_at); end if;
  if new.peixun_zd_kunnan_c is distinct from old.peixun_zd_kunnan_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_zd_kunnan_c', old.peixun_zd_kunnan_c, new.peixun_zd_kunnan_c, new.updated_by, new.updated_at); end if;
  if new.peixun_zd_shiye_c is distinct from old.peixun_zd_shiye_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_zd_shiye_c', old.peixun_zd_shiye_c, new.peixun_zd_shiye_c, new.updated_by, new.updated_at); end if;
  if new.peixun_qiye_c is distinct from old.peixun_qiye_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_qiye_c', old.peixun_qiye_c, new.peixun_qiye_c, new.updated_by, new.updated_at); end if;
  if new.peixun_chuangye_c is distinct from old.peixun_chuangye_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_chuangye_c', old.peixun_chuangye_c, new.peixun_chuangye_c, new.updated_by, new.updated_at); end if;
  if new.peixun_baihang_c is distinct from old.peixun_baihang_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_baihang_c', old.peixun_baihang_c, new.peixun_baihang_c, new.updated_by, new.updated_at); end if;
  if new.peixun_gongyi_c is distinct from old.peixun_gongyi_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'peixun_gongyi_c', old.peixun_gongyi_c, new.peixun_gongyi_c, new.updated_by, new.updated_at); end if;
  if new.jineng_sheng_c is distinct from old.jineng_sheng_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'jineng_sheng_c', old.jineng_sheng_c, new.jineng_sheng_c, new.updated_by, new.updated_at); end if;
  if new.jineng_shi_c is distinct from old.jineng_shi_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'jineng_shi_c', old.jineng_shi_c, new.jineng_shi_c, new.updated_by, new.updated_at); end if;
  if new.gjg_sheng_c is distinct from old.gjg_sheng_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'gjg_sheng_c', old.gjg_sheng_c, new.gjg_sheng_c, new.updated_by, new.updated_at); end if;
  if new.gjg_shi_c is distinct from old.gjg_shi_c then insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values (new.report_month, new.region, 'gjg_shi_c', old.gjg_shi_c, new.gjg_shi_c, new.updated_by, new.updated_at); end if;
  return new;
end; $$;
drop trigger if exists trg_fill_log on public.monthly_reports;
create trigger trg_fill_log after update on public.monthly_reports for each row execute function public.record_fill_log();

-- 7.2 插入时触发（视为从 0 变成填报值）
create or replace function public.record_fill_log_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.fill_logs(report_month, region, field, old_value, new_value, filled_by, filled_at) values
    (new.report_month, new.region, 'peixun_zd_biye_c',     0, new.peixun_zd_biye_c,     new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_zd_chuzhong_c', 0, new.peixun_zd_chuzhong_c, new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_zd_nongcun_c',  0, new.peixun_zd_nongcun_c,  new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_zd_tuopin_c',   0, new.peixun_zd_tuopin_c,   new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_zd_kunnan_c',   0, new.peixun_zd_kunnan_c,   new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_zd_shiye_c',    0, new.peixun_zd_shiye_c,    new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_qiye_c',        0, new.peixun_qiye_c,        new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_chuangye_c',    0, new.peixun_chuangye_c,    new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_baihang_c',     0, new.peixun_baihang_c,     new.updated_by, new.updated_at),
    (new.report_month, new.region, 'peixun_gongyi_c',      0, new.peixun_gongyi_c,      new.updated_by, new.updated_at),
    (new.report_month, new.region, 'jineng_sheng_c', 0, new.jineng_sheng_c, new.updated_by, new.updated_at),
    (new.report_month, new.region, 'jineng_shi_c',   0, new.jineng_shi_c,   new.updated_by, new.updated_at),
    (new.report_month, new.region, 'gjg_sheng_c',    0, new.gjg_sheng_c,    new.updated_by, new.updated_at),
    (new.report_month, new.region, 'gjg_shi_c',      0, new.gjg_shi_c,      new.updated_by, new.updated_at);
  return new;
end; $$;
drop trigger if exists trg_fill_log_insert on public.monthly_reports;
create trigger trg_fill_log_insert after insert on public.monthly_reports for each row execute function public.record_fill_log_insert();


-- ========== 8. 预置 12 个填报单位目标 + 太原市（按年） ==========
-- 作用：初始化 2026 年目标数据。使用 ON CONFLICT 防止重复插入报错。
insert into public.regions (year, region, peixun_target, jineng_target, gjg_target) values
  (2026, '太原市',  20000, 10000, 5000),
  (2026, '市本级',    500,    0,    0),
  (2026, '小店区',   2000,  1200,  600),
  (2026, '迎泽区',   2000,  1200,  600),
  (2026, '杏花岭区', 2000,  1500,  800),
  (2026, '尖草坪区', 2000,  1500,  500),
  (2026, '万柏林区', 2000,  1500,  900),
  (2026, '晋源区',   1700,  1200,  500),
  (2026, '清徐县',   1000,   400,  100),
  (2026, '阳曲县',    600,   400,  100),
  (2026, '娄烦县',    300,   200,  100),
  (2026, '古交市',    600,   400,  100),
  (2026, '综改区',   5300,   500,  500)
on conflict (year, region) do nothing;


-- ========== 9. 注册兜底建档 ==========
-- 作用：如果系统开启了自助注册，新用户注册时自动在 profiles 建个空档案。
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict (id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();


-- =========================================================
-- 【关键操作】解决报错与数据导入问题
-- =========================================================

-- 10. 智能绑定县区（解决外键报错）
-- 逻辑：不用你写死的 UUID，直接拿着邮箱去 auth.users 表里查真实的 UUID。
-- 查到了，根据邮箱分配对应的县区名称（拼音映射已修正）。
-- 如果用户已经绑定过了（ON CONFLICT），则自动更新县区和管理员状态，不会报错。
INSERT INTO public.profiles (id, region, is_admin)
SELECT
  au.id,
  CASE
    WHEN au.email = 'admin@data-yst.cn' THEN NULL
    WHEN au.email = 'shibenji@data-yst.cn' THEN '市本级'
    WHEN au.email = 'xiaodian@data-yst.cn' THEN '小店区'
    WHEN au.email = 'yingze@data-yst.cn' THEN '迎泽区'
    WHEN au.email = 'xinghualing@data-yst.cn' THEN '杏花岭区'
    WHEN au.email = 'jiancaoping@data-yst.cn' THEN '尖草坪区'
    WHEN au.email = 'wanbailin@data-yst.cn' THEN '万柏林区'
    WHEN au.email = 'jinyuan@data-yst.cn' THEN '晋源区'
    WHEN au.email = 'qingxu@data-yst.cn' THEN '清徐县'
    WHEN au.email = 'yangqu@data-yst.cn' THEN '阳曲县'
    WHEN au.email = 'loufan@data-yst.cn' THEN '娄烦县'
    WHEN au.email = 'gujiao@data-yst.cn' THEN '古交市'
    WHEN au.email = 'zonggaiqu@data-yst.cn' THEN '综改区'
    ELSE NULL
  END AS region,
  CASE WHEN au.email = 'admin@data-yst.cn' THEN true ELSE false END AS is_admin
FROM auth.users au
WHERE au.email LIKE '%@data-yst.cn' -- 只匹配咱们建的那批业务账号
ON CONFLICT (id) DO UPDATE SET region = EXCLUDED.region, is_admin = EXCLUDED.is_admin;


-- 11. 导入历史累计数据（适配拆分的表结构）
-- 逻辑：将 Excel 里的数据作为 2026-09 月的"当月新增"导入。
-- 因为 Excel 没有细分，我们默认把所有的"培训总数"放进了 peixun_qiye_c（企业职工）列。
INSERT INTO public.monthly_reports (
  report_month, region,
  peixun_qiye_c, jineng_sheng_c, jineng_shi_c, gjg_sheng_c, gjg_shi_c,
  updated_by, updated_at
) VALUES
  ('2026-09','市本级',    238,  0,   1915, 0,   918, NULL, now()),
  ('2026-09','小店区',   2088,  0,    610, 305, 0,   NULL, now()),
  ('2026-09','迎泽区',   2482, 1344, 0,   676, 0,   NULL, now()),
  ('2026-09','杏花岭区', 1465, 507,  125, 335, 36,  NULL, now()),
  ('2026-09','尖草坪区', 2671, 777,  0,   500, 0,   NULL, now()),
  ('2026-09','万柏林区', 946,  464,  286, 464, 51,  NULL, now()),
  ('2026-09','晋源区',   1494, 442,  273, 295, 0,   NULL, now()),
  ('2026-09','清徐县',   1036, 403,  0,   135, 0,   NULL, now()),
  ('2026-09','阳曲县',   526,  0,    420, 0,   120, NULL, now()),
  ('2026-09','娄烦县',   285,  129,  30,  15,  30,  NULL, now()),
  ('2026-09','古交市',   598,  253,  0,   62,  0,   NULL, now()),
  ('2026-09','综改区',   5163, 308,  0,   308, 0,   NULL, now())
ON CONFLICT (region, report_month) DO NOTHING;

-- 执行完毕。
