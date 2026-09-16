-- ==============================================================================
-- FINORA (ระบบบริหารจัดการการเงินส่วนบุคคล) - Supabase Database Schema
-- Run this in Supabase SQL Editor to set up tables, RLS policies, and triggers
-- ==============================================================================

-- 1. Create Profiles Table (เชื่อมกับ Supabase Auth)
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT,
    full_name TEXT DEFAULT 'ผู้ใช้ Finora',
    avatar_url TEXT,
    subscription_tier TEXT DEFAULT 'starter' CHECK (subscription_tier IN ('starter', 'plus', 'pro')),
    subscription_status TEXT DEFAULT 'active',
    currency TEXT DEFAULT 'THB',
    month_start_day INTEGER DEFAULT 1 CHECK (month_start_day BETWEEN 1 AND 28),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Create Categories Table (หมวดหมู่รายรับ-รายจ่าย)
CREATE TABLE IF NOT EXISTS public.categories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
    icon TEXT DEFAULT 'tag',
    color TEXT DEFAULT '#F06292',
    is_default BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Create Transactions Table (รายการบันทึกรายรับ-รายจ่าย)
CREATE TABLE IF NOT EXISTS public.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    category_id UUID REFERENCES public.categories(id) ON DELETE SET NULL,
    type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
    amount NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    date DATE NOT NULL DEFAULT CURRENT_DATE,
    payment_method TEXT DEFAULT 'promptpay' CHECK (payment_method IN ('cash', 'promptpay', 'credit_card', 'bank_transfer', 'other')),
    note TEXT,
    tags TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 4. Create Budgets Table (งบประมาณรายเดือนและรายหมวดหมู่)
CREATE TABLE IF NOT EXISTS public.budgets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    category_id UUID REFERENCES public.categories(id) ON DELETE CASCADE, -- NULL means overall monthly budget
    amount NUMERIC(12, 2) NOT NULL CHECK (amount >= 0),
    month INTEGER NOT NULL CHECK (month BETWEEN 1 AND 12),
    year INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT unique_user_category_month_year UNIQUE NULLS NOT DISTINCT (user_id, category_id, month, year)
);

-- 5. Create Subscriptions Table (ระบบเก็บค่าบริการและแพ็กเกจสมาชิก)
CREATE TABLE IF NOT EXISTS public.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    plan_tier TEXT NOT NULL CHECK (plan_tier IN ('starter', 'plus', 'pro')),
    billing_cycle TEXT DEFAULT 'monthly' CHECK (billing_cycle IN ('monthly', 'yearly')),
    price NUMERIC(10, 2) NOT NULL DEFAULT 0,
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'cancelled', 'expired')),
    payment_reference TEXT,
    starts_at TIMESTAMPTZ DEFAULT NOW(),
    ends_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '30 days'),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ==============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ==============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.budgets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

-- Profiles: Users can only read/update their own profile
CREATE POLICY "Users can read own profile" ON public.profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile" ON public.profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- Categories: Users see their own categories + system defaults
CREATE POLICY "Users can view own and default categories" ON public.categories 
    FOR SELECT USING (auth.uid() = user_id OR is_default = TRUE);
CREATE POLICY "Users can insert own categories" ON public.categories 
    FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own categories" ON public.categories 
    FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own categories" ON public.categories 
    FOR DELETE USING (auth.uid() = user_id);

-- Transactions: Users can only manage their own transactions
CREATE POLICY "Users can manage own transactions" ON public.transactions 
    FOR ALL USING (auth.uid() = user_id);

-- Budgets: Users can only manage their own budgets
CREATE POLICY "Users can manage own budgets" ON public.budgets 
    FOR ALL USING (auth.uid() = user_id);

-- Subscriptions: Users can read own subscriptions
CREATE POLICY "Users can read own subscriptions" ON public.subscriptions 
    FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own subscriptions" ON public.subscriptions 
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- ==============================================================================
-- AUTOMATIC PROFILE CREATION TRIGGER ON SIGNUP
-- ==============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name, avatar_url)
    VALUES (
        new.id,
        new.email,
        COALESCE(new.raw_user_meta_data->>'full_name', 'ผู้ใช้ Finora'),
        COALESCE(new.raw_user_meta_data->>'avatar_url', 'https://api.dicebear.com/7.x/bottts/svg?seed=' || new.id)
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ==============================================================================
-- SEED DEFAULT SYSTEM CATEGORIES
-- ==============================================================================

INSERT INTO public.categories (name, type, icon, color, is_default) VALUES
-- Expense Categories (หมวดรายจ่าย)
('อาหารและเครื่องดื่ม', 'expense', 'utensils', '#FF85A2', true),
('การเดินทาง & ยานพาหนะ', 'expense', 'car', '#FFAAA6', true),
('ช้อปปิ้ง & ของใช้', 'expense', 'shopping-bag', '#FFB7B2', true),
('ที่อยู่อาศัย & ค่าน้ำไฟ', 'expense', 'home', '#F48FB1', true),
('ความบันเทิง & สตรีมมิ่ง', 'expense', 'film', '#CE93D8', true),
('สุขภาพ & ยารักษาโรค', 'expense', 'heart-pulse', '#F06292', true),
('การศึกษา & พัฒนาตนเอง', 'expense', 'book-open', '#BA68C8', true),
('ค่าใช้จ่ายอื่นๆ', 'expense', 'more-horizontal', '#E57373', true),
-- Income Categories (หมวดรายรับ)
('เงินเดือนประจำ', 'income', 'briefcase', '#81C784', true),
('งานฟรีแลนซ์ & จ๊อบเสริม', 'income', 'laptop', '#4DB6AC', true),
('โบนัส & เงินรางวัล', 'income', 'gift', '#64B5F6', true),
('ผลตอบแทนการลงทุน & ดอกเบี้ย', 'income', 'trending-up', '#BA68C8', true),
('รายรับอื่นๆ', 'income', 'dollar-sign', '#A1887F', true)
ON CONFLICT DO NOTHING;
