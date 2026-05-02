-- ============================================================
-- TourPro - Supabase Database Schema
-- Run this in Supabase SQL Editor to set up the backend
-- ============================================================

-- 0. EXTENSIONS
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 1. CUSTOM TYPES
CREATE TYPE public.user_role       AS ENUM ('admin', 'handler', 'passenger');
CREATE TYPE public.tour_status     AS ENUM ('planning', 'collecting', 'booked', 'assigning', 'locked', 'completed');
CREATE TYPE public.payment_status  AS ENUM ('paid', 'notPaid');
CREATE TYPE public.age_group       AS ENUM ('elder', 'young', 'other');
CREATE TYPE public.seat_type       AS ENUM ('singleSofa', 'doubleSofa');

-- 2. TABLES

-- 2a. profiles (extends auth.users)
CREATE TABLE public.profiles (
  id         UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL DEFAULT '',
  phone      TEXT NOT NULL DEFAULT '',
  role       public.user_role NOT NULL DEFAULT 'passenger',
  avatar_url TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2b. tours
CREATE TABLE public.tours (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title           TEXT NOT NULL,
  from_city       TEXT NOT NULL,
  to_city         TEXT NOT NULL,
  departure_date  TIMESTAMPTZ NOT NULL,
  return_date     TIMESTAMPTZ,
  price_per_seat  NUMERIC(10,2) NOT NULL,
  description     TEXT,
  status          public.tour_status NOT NULL DEFAULT 'planning',
  handler_id      UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_by      UUID NOT NULL REFERENCES public.profiles(id),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2c. passengers
CREATE TABLE public.passengers (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tour_id         UUID NOT NULL REFERENCES public.tours(id) ON DELETE CASCADE,
  user_id         UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
  name            TEXT NOT NULL,
  phone           TEXT NOT NULL,
  requested_seats INTEGER NOT NULL DEFAULT 1,
  seat_preference public.seat_type NOT NULL DEFAULT 'singleSofa',
  age_group       public.age_group NOT NULL DEFAULT 'other',
  assigned_seats  TEXT[] NOT NULL DEFAULT '{}',
  payment_status  public.payment_status NOT NULL DEFAULT 'notPaid',
  is_handler      BOOLEAN NOT NULL DEFAULT FALSE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2d. bus_details (one per tour)
CREATE TABLE public.bus_details (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tour_id       UUID NOT NULL UNIQUE REFERENCES public.tours(id) ON DELETE CASCADE,
  bus_number    TEXT NOT NULL,
  driver_name   TEXT NOT NULL,
  driver_phone  TEXT NOT NULL,
  owner_name    TEXT,
  owner_phone   TEXT,
  is_ac         BOOLEAN NOT NULL DEFAULT TRUE,
  bus_type      TEXT NOT NULL DEFAULT 'Semi-Sleeper',
  total_seats   INTEGER NOT NULL DEFAULT 0,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. INDEXES
CREATE INDEX idx_tours_status      ON public.tours(status);
CREATE INDEX idx_tours_created_by  ON public.tours(created_by);
CREATE INDEX idx_tours_handler_id  ON public.tours(handler_id);
CREATE INDEX idx_tours_departure   ON public.tours(departure_date);
CREATE INDEX idx_passengers_tour   ON public.passengers(tour_id);
CREATE INDEX idx_passengers_user   ON public.passengers(user_id);
CREATE INDEX idx_passengers_phone  ON public.passengers(phone);
CREATE INDEX idx_bus_details_tour  ON public.bus_details(tour_id);

-- 4. UPDATED_AT TRIGGER
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tours_updated_at
  BEFORE UPDATE ON public.tours
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_bus_details_updated_at
  BEFORE UPDATE ON public.bus_details
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- 5. AUTO-CREATE PROFILE ON SIGNUP
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, name, phone, role)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'name', ''),
    COALESCE(NEW.phone, NEW.raw_user_meta_data->>'phone', ''),
    COALESCE((NEW.raw_user_meta_data->>'role')::public.user_role, 'passenger')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- 6. ROW LEVEL SECURITY
ALTER TABLE public.profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tours       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.passengers  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bus_details ENABLE ROW LEVEL SECURITY;

-- Helper: get current user's role
CREATE OR REPLACE FUNCTION public.current_user_role()
RETURNS public.user_role AS $$
  SELECT role FROM public.profiles WHERE id = auth.uid();
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- PROFILES policies
CREATE POLICY "profiles_select" ON public.profiles
  FOR SELECT USING (true);

CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE USING (id = auth.uid());

CREATE POLICY "profiles_update_admin" ON public.profiles
  FOR UPDATE USING (public.current_user_role() = 'admin');

-- TOURS policies
CREATE POLICY "tours_select" ON public.tours
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "tours_insert_admin" ON public.tours
  FOR INSERT WITH CHECK (public.current_user_role() = 'admin');

CREATE POLICY "tours_update" ON public.tours
  FOR UPDATE USING (
    public.current_user_role() = 'admin'
    OR handler_id = auth.uid()
  );

CREATE POLICY "tours_delete_admin" ON public.tours
  FOR DELETE USING (public.current_user_role() = 'admin');

-- PASSENGERS policies
CREATE POLICY "passengers_select" ON public.passengers
  FOR SELECT USING (
    public.current_user_role() = 'admin'
    OR user_id = auth.uid()
    OR tour_id IN (SELECT id FROM public.tours WHERE handler_id = auth.uid())
  );

CREATE POLICY "passengers_insert" ON public.passengers
  FOR INSERT WITH CHECK (
    public.current_user_role() = 'admin'
    OR (user_id = auth.uid() AND public.current_user_role() = 'passenger')
  );

CREATE POLICY "passengers_update" ON public.passengers
  FOR UPDATE USING (
    public.current_user_role() = 'admin'
    OR (
      public.current_user_role() = 'handler'
      AND tour_id IN (SELECT id FROM public.tours WHERE handler_id = auth.uid())
    )
  );

CREATE POLICY "passengers_delete" ON public.passengers
  FOR DELETE USING (public.current_user_role() = 'admin');

-- BUS_DETAILS policies
CREATE POLICY "bus_details_select" ON public.bus_details
  FOR SELECT USING (auth.uid() IS NOT NULL);

CREATE POLICY "bus_details_insert" ON public.bus_details
  FOR INSERT WITH CHECK (public.current_user_role() = 'admin');

CREATE POLICY "bus_details_update" ON public.bus_details
  FOR UPDATE USING (public.current_user_role() = 'admin');

CREATE POLICY "bus_details_delete" ON public.bus_details
  FOR DELETE USING (public.current_user_role() = 'admin');

-- 7. REALTIME
ALTER PUBLICATION supabase_realtime ADD TABLE public.tours;
ALTER PUBLICATION supabase_realtime ADD TABLE public.passengers;
ALTER PUBLICATION supabase_realtime ADD TABLE public.bus_details;
