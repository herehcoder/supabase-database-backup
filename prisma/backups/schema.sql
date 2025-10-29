


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."commission_status" AS ENUM (
    'pending',
    'approved',
    'paid',
    'rejected'
);


ALTER TYPE "public"."commission_status" OWNER TO "postgres";


CREATE TYPE "public"."commission_type" AS ENUM (
    'percentage',
    'fixed'
);


ALTER TYPE "public"."commission_type" OWNER TO "postgres";


CREATE TYPE "public"."coupon_discount_type" AS ENUM (
    'percentage',
    'fixed'
);


ALTER TYPE "public"."coupon_discount_type" OWNER TO "postgres";


CREATE TYPE "public"."discount_type_new" AS ENUM (
    'percentage',
    'fixed'
);


ALTER TYPE "public"."discount_type_new" OWNER TO "postgres";


CREATE TYPE "public"."order_status" AS ENUM (
    'pending',
    'completed',
    'cancelled',
    'refunded'
);


ALTER TYPE "public"."order_status" OWNER TO "postgres";


CREATE TYPE "public"."payment_status" AS ENUM (
    'pending',
    'completed',
    'failed',
    'refunded'
);


ALTER TYPE "public"."payment_status" OWNER TO "postgres";


CREATE TYPE "public"."product_type" AS ENUM (
    'digital',
    'physical'
);


ALTER TYPE "public"."product_type" OWNER TO "postgres";


CREATE TYPE "public"."sale_status" AS ENUM (
    'pending',
    'confirmed',
    'cancelled',
    'refunded'
);


ALTER TYPE "public"."sale_status" OWNER TO "postgres";


CREATE TYPE "public"."subscription_duration_unit" AS ENUM (
    'minutes',
    'hours',
    'days',
    'months'
);


ALTER TYPE "public"."subscription_duration_unit" OWNER TO "postgres";


CREATE TYPE "public"."subscription_status" AS ENUM (
    'active',
    'expired',
    'cancelled',
    'blocked'
);


ALTER TYPE "public"."subscription_status" OWNER TO "postgres";


CREATE TYPE "public"."user_status" AS ENUM (
    'active',
    'inactive',
    'suspended'
);


ALTER TYPE "public"."user_status" OWNER TO "postgres";


CREATE TYPE "public"."withdrawal_status" AS ENUM (
    'pending',
    'approved',
    'rejected',
    'paid'
);


ALTER TYPE "public"."withdrawal_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_subscription_to_company"("p_company_id" integer, "p_subscription_id" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_subscription RECORD;
  v_expires_at TIMESTAMP WITH TIME ZONE;
  v_result jsonb;
BEGIN
  -- Get subscription details
  SELECT name, price, duration_value, duration_unit
  INTO v_subscription
  FROM public.subscriptions
  WHERE id = p_subscription_id;
  
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Subscription not found with id: %', p_subscription_id;
  END IF;
  
  -- Calculate expiration date based on duration
  CASE v_subscription.duration_unit
    WHEN 'minutes' THEN
      v_expires_at := NOW() + (v_subscription.duration_value || ' minutes')::INTERVAL;
    WHEN 'hours' THEN
      v_expires_at := NOW() + (v_subscription.duration_value || ' hours')::INTERVAL;
    WHEN 'days' THEN
      v_expires_at := NOW() + (v_subscription.duration_value || ' days')::INTERVAL;
    WHEN 'months' THEN
      v_expires_at := NOW() + (v_subscription.duration_value || ' months')::INTERVAL;
    ELSE
      RAISE EXCEPTION 'Invalid duration unit: %', v_subscription.duration_unit;
  END CASE;
  
  -- Deactivate any existing active subscriptions for this company
  UPDATE public.company_subscriptions
  SET status = 'expired'::subscription_status,
      updated_at = NOW()
  WHERE company_id = p_company_id 
    AND status = 'active'::subscription_status;
  
  -- Insert new subscription record
  INSERT INTO public.company_subscriptions (
    company_id,
    subscription_id,
    signed_at,
    expires_at,
    status,
    notify_3_days_sent,
    created_at,
    updated_at
  ) VALUES (
    p_company_id,
    p_subscription_id,
    NOW(),
    v_expires_at,
    'active'::subscription_status,
    false,
    NOW(),
    NOW()
  );
  
  -- Update company subscription reference
  UPDATE public.companies
  SET subscription_id = p_subscription_id,
      updated_at = NOW()
  WHERE id = p_company_id;
  
  -- Build result object
  v_result := jsonb_build_object(
    'success', true,
    'expires_at', v_expires_at,
    'subscription_name', v_subscription.name,
    'duration', v_subscription.duration_value || ' ' || v_subscription.duration_unit
  );
  
  RAISE NOTICE 'Subscription assigned successfully: Company % -> Subscription % (expires: %)', 
    p_company_id, p_subscription_id, v_expires_at;
  
  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."assign_subscription_to_company"("p_company_id" integer, "p_subscription_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_engagement_score"("p_session_id" character varying) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    interaction_score INTEGER := 0;
    time_score INTEGER := 0;
    progress_score INTEGER := 0;
    total_score INTEGER := 0;
    interaction_count INTEGER;
    active_time INTEGER;
    progress_events INTEGER;
BEGIN
    -- Contar interações
    SELECT COUNT(*) INTO interaction_count
    FROM public.engagement_events
    WHERE session_id = p_session_id
    AND event_type IN ('interaction', 'click', 'scroll', 'form_start', 'form_complete', 'checkout_start');
    
    -- Obter tempo ativo
    SELECT COALESCE(total_active_time, 0) INTO active_time
    FROM public.active_sessions
    WHERE session_id = p_session_id;
    
    -- Contar eventos de progresso
    SELECT COUNT(DISTINCT event_type) INTO progress_events
    FROM public.engagement_events
    WHERE session_id = p_session_id
    AND event_type IN ('form_start', 'form_complete', 'checkout_start', 'checkout_complete');
    
    -- Calcular scores
    interaction_score := LEAST((interaction_count * 4), 40); -- Max 40 pontos
    time_score := LEAST((active_time / 60), 30); -- Max 30 pontos (30 min)
    progress_score := (progress_events * 7.5); -- Max 30 pontos (4 eventos)
    
    total_score := interaction_score + time_score + progress_score;
    
    RETURN LEAST(total_score, 100); -- Max 100 pontos
END;
$$;


ALTER FUNCTION "public"."calculate_engagement_score"("p_session_id" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_product_commission"("p_product_name" "text", "p_sale_amount" numeric, "p_company_id" integer, "p_manual_commission" numeric DEFAULT NULL::numeric) RETURNS numeric
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  product_record RECORD;
  commission_record RECORD;
  calculated_commission NUMERIC := 0;
BEGIN
  -- Se comissão manual foi fornecida, usar ela
  IF p_manual_commission IS NOT NULL AND p_manual_commission >= 0 THEN
    RETURN p_manual_commission;
  END IF;
  
  -- Buscar produto pelo nome e empresa
  SELECT id INTO product_record
  FROM public.products 
  WHERE name = p_product_name 
  AND company_id = p_company_id
  LIMIT 1;
  
  -- Se produto não encontrado, retornar 0
  IF NOT FOUND THEN
    RAISE NOTICE 'Produto % não encontrado para company_id %', p_product_name, p_company_id;
    RETURN 0;
  END IF;
  
  -- Buscar configuração de comissão do produto
  SELECT value, type INTO commission_record
  FROM public.product_commissions 
  WHERE product_id = product_record.id;
  
  -- Se não há comissão configurada, retornar 0
  IF NOT FOUND THEN
    RAISE NOTICE 'Nenhuma comissão configurada para produto %', p_product_name;
    RETURN 0;
  END IF;
  
  -- Calcular comissão baseada no tipo
  IF commission_record.type = 'percentage' THEN
    calculated_commission := (p_sale_amount * commission_record.value) / 100;
    RAISE NOTICE 'Comissão calculada: % de % = %', commission_record.value, p_sale_amount, calculated_commission;
  ELSE -- fixed
    calculated_commission := commission_record.value;
    RAISE NOTICE 'Comissão fixa aplicada: %', calculated_commission;
  END IF;
  
  -- Validar se comissão não é absurda (mais que 50% do valor da venda)
  IF calculated_commission > (p_sale_amount * 0.5) THEN
    RAISE NOTICE 'Comissão muito alta detectada (%), limitando a 50%% do valor da venda', calculated_commission;
    calculated_commission := p_sale_amount * 0.5;
  END IF;
  
  RETURN calculated_commission;
END;
$$;


ALTER FUNCTION "public"."calculate_product_commission"("p_product_name" "text", "p_sale_amount" numeric, "p_company_id" integer, "p_manual_commission" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."calculate_subscription_expiry"("p_duration_value" integer, "p_duration_unit" "public"."subscription_duration_unit") RETURNS timestamp with time zone
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  CASE p_duration_unit
    WHEN 'days' THEN
      RETURN NOW() + (p_duration_value || ' days')::INTERVAL;
    WHEN 'months' THEN
      RETURN NOW() + (p_duration_value || ' months')::INTERVAL;
    WHEN 'minutes' THEN
      RETURN NOW() + (p_duration_value || ' minutes')::INTERVAL;
    ELSE
      RETURN NOW() + '30 days'::INTERVAL;
  END CASE;
END;
$$;


ALTER FUNCTION "public"."calculate_subscription_expiry"("p_duration_value" integer, "p_duration_unit" "public"."subscription_duration_unit") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_mlm_override_commissions"("p_sale_id" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  UPDATE public.affiliate_commissions_earned 
  SET status = 'cancelled'::commission_status, updated_at = NOW()
  WHERE source_sale_id = p_sale_id 
  AND commission_type = 'override'
  AND status = 'pending';
  
  RAISE NOTICE '[MLM] Cancelled override commissions for sale %', p_sale_id;
END;
$$;


ALTER FUNCTION "public"."cancel_mlm_override_commissions"("p_sale_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cascade_delete_company"("p_company_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_email TEXT;
  is_superadmin BOOLEAN := false;
  user_record RECORD;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  current_user_email := (SELECT email FROM auth.users WHERE id = auth.uid());
  
  IF current_user_email = 'superadmin@sistema.com' THEN
    is_superadmin := true;
  END IF;
  
  -- Se não for SuperAdmin, verificar no cache
  IF NOT is_superadmin THEN
    SELECT (role_id = 1) INTO is_superadmin
    FROM public.user_cache 
    WHERE auth_user_id = auth.uid();
  END IF;
  
  -- Só SuperAdmin pode executar esta função
  IF NOT COALESCE(is_superadmin, false) THEN
    RAISE EXCEPTION 'Apenas SuperAdmin pode executar deleção em cascata de empresas';
  END IF;

  -- Log da operação
  RAISE NOTICE 'SuperAdmin % iniciando deleção cascata da empresa %', current_user_email, p_company_id;

  BEGIN
    -- 1. Deletar todos os usuários da empresa usando nossa função
    FOR user_record IN SELECT id FROM public.users WHERE company_id = p_company_id LOOP
      IF NOT public.cascade_delete_user(user_record.id) THEN
        RAISE EXCEPTION 'Falha ao deletar usuário % da empresa %', user_record.id, p_company_id;
      END IF;
    END LOOP;

    -- 2. Deletar dados da empresa
    DELETE FROM public.company_settings WHERE company_id = p_company_id;
    DELETE FROM public.products WHERE company_id = p_company_id;
    DELETE FROM public.sales WHERE company_id = p_company_id;
    DELETE FROM public.coupons WHERE company_id = p_company_id;
    DELETE FROM public.leads WHERE company_id = p_company_id;
    DELETE FROM public.members WHERE company_id = p_company_id;
    DELETE FROM public.membership_plans WHERE company_id = p_company_id;

    -- 3. Finalmente deletar a empresa
    DELETE FROM public.companies WHERE id = p_company_id;

    RAISE NOTICE 'Empresa % deletada com sucesso pelo SuperAdmin %', p_company_id, current_user_email;
    RETURN true;

  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Erro na deleção da empresa %: %', p_company_id, SQLERRM;
    RETURN false;
  END;
END;
$$;


ALTER FUNCTION "public"."cascade_delete_company"("p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cascade_delete_user"("p_user_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_email TEXT;
  is_superadmin BOOLEAN := false;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  current_user_email := (SELECT email FROM auth.users WHERE id = auth.uid());
  
  IF current_user_email = 'superadmin@sistema.com' THEN
    is_superadmin := true;
  END IF;
  
  -- Se não for SuperAdmin, verificar no cache
  IF NOT is_superadmin THEN
    SELECT (role_id = 1) INTO is_superadmin
    FROM public.user_cache 
    WHERE auth_user_id = auth.uid();
  END IF;
  
  -- Só SuperAdmin pode executar esta função
  IF NOT COALESCE(is_superadmin, false) THEN
    RAISE EXCEPTION 'Apenas SuperAdmin pode executar deleção em cascata de usuários';
  END IF;

  -- Log da operação
  RAISE NOTICE 'SuperAdmin % iniciando deleção cascata do usuário %', current_user_email, p_user_id;

  BEGIN
    -- 1. Deletar logs de auditoria relacionados ao usuário (tanto como user_id quanto como changed_by)
    DELETE FROM public.user_audit_logs WHERE user_id = p_user_id;
    DELETE FROM public.user_audit_logs WHERE changed_by = p_user_id;

    -- 2. Atualizar vendas para remover referência do usuário (manter histórico)
    UPDATE public.sales 
    SET affiliate_user_id = NULL, commission_amount = 0
    WHERE affiliate_user_id = p_user_id;
    
    -- 3. Remover associação de cupons (manter cupons, remover apenas a associação)
    UPDATE public.coupons 
    SET affiliate_user_id = NULL
    WHERE affiliate_user_id = p_user_id;

    -- 4. Deletar dados financeiros
    DELETE FROM public.affiliate_commissions_earned WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_payments WHERE user_id = p_user_id;
    DELETE FROM public.payments WHERE affiliate_user_id = p_user_id;
    DELETE FROM public.withdrawal_requests WHERE user_id = p_user_id;

    -- 5. Deletar dados de afiliado
    DELETE FROM public.affiliate_conversions WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_link_clicks WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_links WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_profiles WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_addresses WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_bank_data WHERE user_id = p_user_id;

    -- 6. Deletar dados pessoais
    DELETE FROM public.user_bank_details WHERE user_id = p_user_id;
    DELETE FROM public.user_settings WHERE user_id = p_user_id;
    DELETE FROM public.notifications WHERE user_id = p_user_id;

    -- 7. Deletar cache do usuário
    DELETE FROM public.user_cache WHERE user_id = p_user_id;

    -- 8. Finalmente deletar o usuário
    DELETE FROM public.users WHERE id = p_user_id;

    RAISE NOTICE 'Usuário % deletado com sucesso pelo SuperAdmin %', p_user_id, current_user_email;
    RETURN true;

  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Erro na deleção do usuário %: %', p_user_id, SQLERRM;
    RETURN false;
  END;
END;
$$;


ALTER FUNCTION "public"."cascade_delete_user"("p_user_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_and_deactivate_coupon"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Log para debug
  RAISE NOTICE 'Verificando limite do cupom: %, Usos: %, Limite: %', 
    NEW.code, NEW.used_count, NEW.max_uses;
  
  -- Se o cupom tem limite definido e atingiu o limite, desativar
  IF NEW.max_uses IS NOT NULL AND NEW.used_count >= NEW.max_uses THEN
    NEW.active = false;
    RAISE NOTICE 'Cupom % desativado por atingir o limite de %', NEW.code, NEW.max_uses;
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_and_deactivate_coupon"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_company_not_blocked"() RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
  user_company_id INTEGER;
BEGIN
  -- Obter company_id do usuário atual
  user_company_id := get_current_user_company();
  
  RAISE NOTICE 'check_company_not_blocked: Company ID: %', COALESCE(user_company_id::text, 'NULL');
  
  -- Se não tem company_id, considerar não bloqueado para super admin
  IF user_company_id IS NULL THEN
    RETURN get_current_user_role() = 1; -- Super admin pode operar sem company
  END IF;
  
  -- Por enquanto, sempre retornar true (implementação futura de bloqueio)
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."check_company_not_blocked"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_product_stock"("product_id" integer, "required_quantity" integer DEFAULT 1) RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
  current_stock INTEGER;
  is_unlimited BOOLEAN;
BEGIN
  -- Buscar informações do produto
  SELECT stock_quantity, unlimited_stock 
  INTO current_stock, is_unlimited
  FROM public.products 
  WHERE id = product_id;
  
  -- Se não encontrou o produto, retornar false
  IF NOT FOUND THEN
    RETURN FALSE;
  END IF;
  
  -- Se tem estoque ilimitado, sempre disponível
  IF is_unlimited THEN
    RETURN TRUE;
  END IF;
  
  -- Verificar se tem estoque suficiente
  RETURN current_stock >= required_quantity;
END;
$$;


ALTER FUNCTION "public"."check_product_stock"("product_id" integer, "required_quantity" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_old_engagement_data"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    DELETE FROM public.engagement_events 
    WHERE timestamp < NOW() - INTERVAL '90 days';
    
    UPDATE public.active_sessions 
    SET is_active = false
    WHERE last_activity < NOW() - INTERVAL '4 hours' AND is_active = true;
    
    DELETE FROM public.active_sessions
    WHERE is_active = false AND last_activity < NOW() - INTERVAL '30 days';
    
    DELETE FROM public.thank_you_page_visits
    WHERE visited_at < NOW() - INTERVAL '30 days';
END;
$$;


ALTER FUNCTION "public"."cleanup_old_engagement_data"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_old_logo"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Se houve mudança na URL do logo e a URL antiga existe
  IF OLD.platform_logo_url IS NOT NULL AND OLD.platform_logo_url != NEW.platform_logo_url THEN
    -- Extrair nome do arquivo da URL antiga
    DECLARE
      old_file_path TEXT;
    BEGIN
      old_file_path := regexp_replace(OLD.platform_logo_url, '^.*/storage/v1/object/public/platform-logos/', '');
      -- Deletar arquivo antigo do storage
      DELETE FROM storage.objects 
      WHERE bucket_id = 'platform-logos' AND name = old_file_path;
    EXCEPTION WHEN OTHERS THEN
      -- Ignorar erros de limpeza
      NULL;
    END;
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."cleanup_old_logo"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_affiliate_coupon"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  coupon_code TEXT;
  discount_config RECORD;
  coupon_value NUMERIC;
  coupon_type discount_type_new;
BEGIN
  -- Gerar código único do cupom baseado no código do afiliado
  coupon_code := 'CUP' || NEW.code;
  
  -- Buscar configuração de desconto do produto
  SELECT discount_type, discount_value, max_discount_amount 
  INTO discount_config
  FROM public.product_discount_settings 
  WHERE product_id = NEW.product_id AND company_id = NEW.company_id;
  
  -- Se encontrou configuração específica, usar ela
  IF FOUND THEN
    coupon_type := discount_config.discount_type;
    coupon_value := discount_config.discount_value;
    
    RAISE NOTICE 'Usando configuração de desconto específica: tipo=%, valor=%', 
      coupon_type, coupon_value;
  ELSE
    -- Fallback: valores padrão conservadores se não há configuração
    coupon_type := 'percentage';
    coupon_value := 5; -- 5% padrão
    
    RAISE NOTICE 'Usando configuração padrão de desconto: 5%%';
  END IF;
  
  -- Criar cupom específico para este produto e afiliado
  INSERT INTO public.coupons (
    code,
    company_id,
    product_id,
    affiliate_user_id,
    discount_type,
    value,
    max_uses,
    active,
    created_at,
    updated_at
  ) VALUES (
    coupon_code,
    NEW.company_id,
    NEW.product_id,
    NEW.user_id,
    coupon_type,
    coupon_value,
    NULL, -- Ilimitado
    true,
    NOW(),
    NOW()
  )
  ON CONFLICT (code, company_id) DO UPDATE SET
    product_id = EXCLUDED.product_id,
    affiliate_user_id = EXCLUDED.affiliate_user_id,
    discount_type = EXCLUDED.discount_type,
    value = EXCLUDED.value,
    active = true,
    updated_at = NOW();
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."create_affiliate_coupon"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_commission_on_sale"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  final_commission NUMERIC;
BEGIN
  -- Log para debug
  RAISE NOTICE 'Processando venda ID: %, Produto: %, Valor: %, Afiliado: %, Company: %', 
    NEW.id, NEW.product_name, NEW.amount, NEW.affiliate_user_id, NEW.company_id;
  
  -- Só processar se houver afiliado
  IF NEW.affiliate_user_id IS NOT NULL THEN
    -- Calcular comissão (automática ou manual)
    final_commission := public.calculate_product_commission(
      NEW.product_name,
      NEW.amount,
      NEW.company_id,
      NEW.commission_amount -- Se NULL, será calculado automaticamente
    );
    
    -- Atualizar o campo commission_amount na própria venda com o valor calculado
    NEW.commission_amount := final_commission;
    
    RAISE NOTICE 'Comissão final calculada: %', final_commission;
    
    -- Criar registro de comissão apenas se valor > 0
    IF final_commission > 0 THEN
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        order_item_id,
        amount,
        status,
        earned_at
      ) VALUES (
        NEW.affiliate_user_id,
        NEW.company_id,
        NULL,
        final_commission,
        'pending'::commission_status,
        NEW.sale_date
      );
      
      RAISE NOTICE 'Registro de comissão criado com sucesso';
    ELSE
      RAISE NOTICE 'Comissão zero - registro não criado';
    END IF;
  ELSE
    RAISE NOTICE 'Venda sem afiliado - comissão não processada';
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."create_commission_on_sale"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_commission_on_sale_update"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  final_commission NUMERIC;
BEGIN
  -- Log para debug
  RAISE NOTICE 'Status da venda alterado: Old: %, New: %', OLD.status, NEW.status;
  
  -- Só processar comissão quando status mudar para 'confirmed'
  IF NEW.status = 'confirmed' AND OLD.status != 'confirmed' AND NEW.affiliate_user_id IS NOT NULL THEN
    -- Calcular comissão (automática ou manual)
    final_commission := public.calculate_product_commission(
      NEW.product_name,
      NEW.amount,
      NEW.company_id,
      NEW.commission_amount -- Se NULL, será calculado automaticamente
    );
    
    -- Atualizar o campo commission_amount na própria venda com o valor calculado
    NEW.commission_amount := final_commission;
    
    RAISE NOTICE 'Comissão final calculada: %', final_commission;
    
    -- Criar registro de comissão apenas se valor > 0
    IF final_commission > 0 THEN
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        order_item_id,
        amount,
        status,
        earned_at
      ) VALUES (
        NEW.affiliate_user_id,
        NEW.company_id,
        NULL,
        final_commission,
        'pending'::commission_status,
        NEW.sale_date
      );
      
      RAISE NOTICE 'Registro de comissão criado com sucesso';
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."create_commission_on_sale_update"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_mlm_override_commissions"("p_sale_id" integer, "p_direct_affiliate_user_id" integer, "p_company_id" integer, "p_sale_amount" numeric, "p_sale_date" timestamp without time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  upline_record RECORD;
  override_amount NUMERIC;
BEGIN
  -- Get upline affiliates and create override commissions
  FOR upline_record IN 
    SELECT * FROM public.get_affiliate_upline(p_direct_affiliate_user_id, p_company_id)
  LOOP
    -- Calculate override commission amount
    override_amount := (p_sale_amount * upline_record.percentage) / 100;
    
    -- Only create commission if amount > 0
    IF override_amount > 0 THEN
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        source_sale_id,
        amount,
        commission_type,
        level,
        source_affiliate_user_id,
        status,
        earned_at,
        created_at,
        updated_at
      ) VALUES (
        upline_record.user_id,
        p_company_id,
        p_sale_id,
        override_amount,
        'override',
        upline_record.level,
        p_direct_affiliate_user_id,
        'pending'::commission_status,
        p_sale_date,
        NOW(),
        NOW()
      );
      
      RAISE NOTICE '[MLM] Override commission created: Level % - User % - Amount %', 
        upline_record.level, upline_record.user_id, override_amount;
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."create_mlm_override_commissions"("p_sale_id" integer, "p_direct_affiliate_user_id" integer, "p_company_id" integer, "p_sale_amount" numeric, "p_sale_date" timestamp without time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_notification"("p_user_id" integer, "p_company_id" integer, "p_title" character varying, "p_message" "text", "p_type" character varying DEFAULT 'info'::character varying, "p_data" "jsonb" DEFAULT NULL::"jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  notification_id INTEGER;
BEGIN
  INSERT INTO public.notifications (user_id, company_id, title, message, type, data)
  VALUES (p_user_id, p_company_id, p_title, p_message, p_type, p_data)
  RETURNING id INTO notification_id;
  
  RETURN notification_id;
END;
$$;


ALTER FUNCTION "public"."create_notification"("p_user_id" integer, "p_company_id" integer, "p_title" character varying, "p_message" "text", "p_type" character varying, "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."debug_rls_products"() RETURNS TABLE("current_auth_uid" "text", "user_role_value" integer, "user_company_value" integer, "company_blocked" boolean, "can_insert" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY SELECT 
    COALESCE(auth.uid()::text, 'NULL'),
    get_current_user_role(),
    get_current_user_company(),
    NOT check_company_not_blocked(),
    (
      get_current_user_role() = 1 OR
      (get_current_user_role() = 2 AND get_current_user_company() IS NOT NULL)
    );
END;
$$;


ALTER FUNCTION "public"."debug_rls_products"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."force_delete_company_with_all_dependencies"("p_company_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_email TEXT;
  is_superadmin BOOLEAN := false;
  user_record RECORD;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  current_user_email := (SELECT email FROM auth.users WHERE id = auth.uid());
  
  IF current_user_email = 'superadmin@sistema.com' THEN
    is_superadmin := true;
  END IF;
  
  -- Se não for SuperAdmin, verificar no cache
  IF NOT is_superadmin THEN
    SELECT (role_id = 1) INTO is_superadmin
    FROM public.user_cache 
    WHERE auth_user_id = auth.uid();
  END IF;
  
  -- Só SuperAdmin pode executar esta função
  IF NOT COALESCE(is_superadmin, false) THEN
    RAISE EXCEPTION 'Apenas SuperAdmin pode executar deleção forçada de empresas';
  END IF;

  -- Log da operação
  RAISE NOTICE 'SuperAdmin % iniciando deleção FORÇADA TOTAL da empresa %', current_user_email, p_company_id;

  BEGIN
    -- ETAPA 1: Deletar TODOS os usuários da empresa usando função ultimate
    FOR user_record IN SELECT id FROM public.users WHERE company_id = p_company_id LOOP
      RAISE NOTICE 'Deletando usuário % da empresa %', user_record.id, p_company_id;
      
      -- Usar a função ultimate que agora funciona corretamente
      IF NOT public.ultimate_force_delete_user(user_record.id) THEN
        RAISE NOTICE 'Falha ao deletar usuário %, continuando...', user_record.id;
      END IF;
    END LOOP;

    -- ETAPA 2: Limpar TODAS as tabelas relacionadas à empresa (incluindo MLM)
    -- Deletar configurações MLM da empresa (NOVO - era isso que estava faltando!)
    DELETE FROM public.company_mlm_levels WHERE company_id = p_company_id;
    RAISE NOTICE 'Deletados company_mlm_levels da empresa %', p_company_id;
    
    -- Deletar configurações da empresa
    DELETE FROM public.company_settings WHERE company_id = p_company_id;
    RAISE NOTICE 'Deletadas company_settings da empresa %', p_company_id;
    
    -- Deletar assinaturas da plataforma
    DELETE FROM public.platform_subscriptions_payments WHERE company_id = p_company_id;
    RAISE NOTICE 'Deletados platform_subscriptions_payments da empresa %', p_company_id;
    
    -- Deletar produtos e suas dependências
    DELETE FROM public.product_commissions WHERE product_id IN (
      SELECT id FROM public.products WHERE company_id = p_company_id
    );
    DELETE FROM public.product_discount_settings WHERE company_id = p_company_id;
    DELETE FROM public.products WHERE company_id = p_company_id;
    RAISE NOTICE 'Deletados produtos da empresa %', p_company_id;
    
    -- Deletar dados restantes (devem estar vazios após deleção dos usuários)
    DELETE FROM public.sales WHERE company_id = p_company_id;
    DELETE FROM public.coupons WHERE company_id = p_company_id;
    DELETE FROM public.leads WHERE company_id = p_company_id;
    DELETE FROM public.members WHERE company_id = p_company_id;
    DELETE FROM public.membership_plans WHERE company_id = p_company_id;
    DELETE FROM public.notifications WHERE company_id = p_company_id;
    DELETE FROM public.affiliate_commissions_earned WHERE company_id = p_company_id;
    DELETE FROM public.affiliate_payments WHERE company_id = p_company_id;
    DELETE FROM public.affiliate_conversions WHERE company_id = p_company_id;
    DELETE FROM public.affiliate_link_clicks WHERE company_id = p_company_id;
    DELETE FROM public.affiliate_links WHERE company_id = p_company_id;
    DELETE FROM public.affiliate_referrals WHERE company_id = p_company_id;
    DELETE FROM public.payments WHERE company_id = p_company_id;
    DELETE FROM public.orders WHERE company_id = p_company_id;
    DELETE FROM public.withdrawal_requests WHERE company_id = p_company_id;
    DELETE FROM public.payment_receipts WHERE company_id = p_company_id;
    DELETE FROM public.engagement_events WHERE company_id = p_company_id;
    DELETE FROM public.active_sessions WHERE company_id = p_company_id;
    RAISE NOTICE 'Limpeza final de dados da empresa %', p_company_id;

    -- ETAPA 3: Finalmente deletar a empresa
    DELETE FROM public.companies WHERE id = p_company_id;
    
    -- Verificar se realmente foi deletada
    IF NOT EXISTS (SELECT 1 FROM public.companies WHERE id = p_company_id) THEN
      RAISE NOTICE 'SUCESSO TOTAL: Empresa % foi COMPLETAMENTE ANIQUILADA pelo SuperAdmin %', p_company_id, current_user_email;
      RETURN true;
    ELSE
      RAISE EXCEPTION 'FALHA CRÍTICA: Empresa % ainda existe após tentativa de deleção', p_company_id;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Erro detectado durante deleção: %', SQLERRM;
    RAISE EXCEPTION 'FALHA NA DELEÇÃO FORÇADA da empresa %: %', p_company_id, SQLERRM;
    RETURN false;
  END;
END;
$$;


ALTER FUNCTION "public"."force_delete_company_with_all_dependencies"("p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."force_delete_user"("p_user_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_email TEXT;
  is_superadmin BOOLEAN := false;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  current_user_email := (SELECT email FROM auth.users WHERE id = auth.uid());
  
  IF current_user_email = 'superadmin@sistema.com' THEN
    is_superadmin := true;
  END IF;
  
  -- Se não for SuperAdmin, verificar no cache
  IF NOT is_superadmin THEN
    SELECT (role_id = 1) INTO is_superadmin
    FROM public.user_cache 
    WHERE auth_user_id = auth.uid();
  END IF;
  
  -- Só SuperAdmin pode executar esta função
  IF NOT COALESCE(is_superadmin, false) THEN
    RAISE EXCEPTION 'Apenas SuperAdmin pode executar deleção forçada de usuários';
  END IF;

  -- Log da operação
  RAISE NOTICE 'SuperAdmin % iniciando deleção SIMPLES FORÇADA do usuário %', current_user_email, p_user_id;

  BEGIN
    -- 1. Remover associações em vendas (manter histórico mas remover referência)
    UPDATE public.sales 
    SET affiliate_user_id = NULL, commission_amount = 0
    WHERE affiliate_user_id = p_user_id;
    
    -- 2. Remover associações em cupons
    UPDATE public.coupons 
    SET affiliate_user_id = NULL
    WHERE affiliate_user_id = p_user_id;

    -- 3. Remover associações em leads
    UPDATE public.leads 
    SET affiliate_user_id = NULL 
    WHERE affiliate_user_id = p_user_id;

    -- 4. Remover associações em pagamentos
    UPDATE public.payments 
    SET affiliate_user_id = NULL 
    WHERE affiliate_user_id = p_user_id;

    -- 5. Deletar dados dependentes em ordem específica
    DELETE FROM public.affiliate_commissions_earned WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_payments WHERE user_id = p_user_id;
    DELETE FROM public.withdrawal_requests WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_conversions WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_link_clicks WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_links WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_profiles WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_addresses WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_bank_data WHERE user_id = p_user_id;
    DELETE FROM public.user_bank_details WHERE user_id = p_user_id;
    DELETE FROM public.user_settings WHERE user_id = p_user_id;
    DELETE FROM public.notifications WHERE user_id = p_user_id;
    DELETE FROM public.user_cache WHERE user_id = p_user_id;

    -- 6. Deletar logs de auditoria por último (pode haver triggers)
    DELETE FROM public.user_audit_logs WHERE user_id = p_user_id;
    DELETE FROM public.user_audit_logs WHERE changed_by = p_user_id;

    -- 7. Finalmente deletar o usuário
    DELETE FROM public.users WHERE id = p_user_id;

    RAISE NOTICE 'Usuário % FORÇADAMENTE deletado pelo SuperAdmin %', p_user_id, current_user_email;
    RETURN true;

  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Erro na deleção: %', SQLERRM;
    RAISE EXCEPTION 'Falha na deleção do usuário %: %', p_user_id, SQLERRM;
    RETURN false;
  END;
END;
$$;


ALTER FUNCTION "public"."force_delete_user"("p_user_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_invitation_token"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  token TEXT;
BEGIN
  -- Gerar token único baseado em timestamp e random
  token := encode(
    digest(
      extract(epoch from now())::text || random()::text || 'affiliate_invite', 
      'sha256'
    ), 
    'hex'
  );
  
  RETURN substring(token from 1 for 32);
END;
$$;


ALTER FUNCTION "public"."generate_invitation_token"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_affiliate_upline"("p_affiliate_user_id" integer, "p_company_id" integer) RETURNS TABLE("level" integer, "user_id" integer, "percentage" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_id INTEGER := p_affiliate_user_id;
  current_level INTEGER := 1;
  sponsor_id INTEGER;
  level_percentage NUMERIC;
BEGIN
  WHILE current_level <= 5 LOOP
    -- Find sponsor for current user
    SELECT sponsor_user_id INTO sponsor_id
    FROM public.affiliate_referrals
    WHERE referred_user_id = current_user_id 
    AND company_id = p_company_id
    AND status = 'active';
    
    -- If no sponsor found, exit loop
    IF sponsor_id IS NULL THEN
      EXIT;
    END IF;
    
    -- Get commission percentage for this level
    SELECT commission_percentage INTO level_percentage
    FROM public.company_mlm_levels
    WHERE company_id = p_company_id AND level = current_level;
    
    -- If no percentage configured for this level, exit
    IF level_percentage IS NULL OR level_percentage = 0 THEN
      EXIT;
    END IF;
    
    -- Return this level's data
    RETURN QUERY SELECT current_level, sponsor_id, level_percentage;
    
    -- Move up one level
    current_user_id := sponsor_id;
    current_level := current_level + 1;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."get_affiliate_upline"("p_affiliate_user_id" integer, "p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_auth_email"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
  RETURN (SELECT email FROM auth.users WHERE id = auth.uid());
END;
$$;


ALTER FUNCTION "public"."get_auth_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_auth_user_email"() RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
  RETURN (SELECT email FROM auth.users WHERE id = auth.uid());
END;
$$;


ALTER FUNCTION "public"."get_auth_user_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_best_affiliate_coupon_optimized"("p_affiliate_user_id" integer, "p_company_id" integer, "p_product_id" integer DEFAULT NULL::integer) RETURNS TABLE("code" character varying, "value" numeric, "discount_type_result" "text")
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Primeiro tentar cupom específico do produto
  IF p_product_id IS NOT NULL THEN
    RETURN QUERY
    SELECT c.code, c.value, c.discount_type::TEXT
    FROM coupons c
    WHERE c.affiliate_user_id = p_affiliate_user_id
      AND c.company_id = p_company_id
      AND c.product_id = p_product_id
      AND c.active = true
      AND (c.expires_at IS NULL OR c.expires_at > CURRENT_DATE)
      AND (c.max_uses IS NULL OR c.used_count < c.max_uses)
    ORDER BY c.value DESC
    LIMIT 1;
    
    -- Se encontrou, retornar
    IF FOUND THEN
      RETURN;
    END IF;
  END IF;
  
  -- Se não encontrou específico, buscar cupom geral do afiliado
  RETURN QUERY
  SELECT c.code, c.value, c.discount_type::TEXT
  FROM coupons c
  WHERE c.affiliate_user_id = p_affiliate_user_id
    AND c.company_id = p_company_id
    AND c.product_id IS NULL
    AND c.active = true
    AND (c.expires_at IS NULL OR c.expires_at > CURRENT_DATE)
    AND (c.max_uses IS NULL OR c.used_count < c.max_uses)
  ORDER BY c.value DESC
  LIMIT 1;
END;
$$;


ALTER FUNCTION "public"."get_best_affiliate_coupon_optimized"("p_affiliate_user_id" integer, "p_company_id" integer, "p_product_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_user_company"() RETURNS integer
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
  user_company_id INTEGER;
  auth_user_id UUID;
  debug_info TEXT := '';
BEGIN
  -- Obter ID do usuário autenticado
  auth_user_id := auth.uid();
  debug_info := debug_info || 'auth_user_id: ' || COALESCE(auth_user_id::text, 'NULL') || '; ';
  
  -- Se não há usuário autenticado, retornar NULL
  IF auth_user_id IS NULL THEN
    RAISE NOTICE 'get_current_user_company: Sem usuário autenticado';
    RETURN NULL;
  END IF;
  
  -- Buscar company_id do cache primeiro
  SELECT company_id INTO user_company_id
  FROM public.user_cache 
  WHERE auth_user_id = auth.uid();
  
  debug_info := debug_info || 'cache_company: ' || COALESCE(user_company_id::text, 'NULL') || '; ';
  
  -- Se encontrou no cache, retornar
  IF user_company_id IS NOT NULL THEN
    RAISE NOTICE 'get_current_user_company: Company encontrada no cache: %', user_company_id;
    RETURN user_company_id;
  END IF;
  
  -- Fallback: buscar diretamente na tabela users
  SELECT u.company_id INTO user_company_id
  FROM public.users u
  INNER JOIN auth.users au ON au.email = u.email
  WHERE au.id = auth_user_id;
  
  debug_info := debug_info || 'direct_company: ' || COALESCE(user_company_id::text, 'NULL') || '; ';
  RAISE NOTICE 'get_current_user_company debug: %', debug_info;
  
  -- Se encontrou, sincronizar no cache
  IF user_company_id IS NOT NULL THEN
    INSERT INTO public.user_cache (auth_user_id, user_id, role_id, company_id, email, updated_at)
    SELECT 
      auth_user_id,
      u.id,
      u.role_id,
      u.company_id,
      u.email,
      NOW()
    FROM public.users u
    INNER JOIN auth.users au ON au.email = u.email
    WHERE au.id = auth_user_id
    ON CONFLICT (auth_user_id) 
    DO UPDATE SET 
      company_id = EXCLUDED.company_id,
      updated_at = NOW();
      
    RAISE NOTICE 'get_current_user_company: Company sincronizada no cache: %', user_company_id;
  END IF;
  
  RETURN user_company_id;
END;
$$;


ALTER FUNCTION "public"."get_current_user_company"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_current_user_role"() RETURNS integer
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
  user_role_id INTEGER;
  auth_user_id UUID;
  debug_info TEXT := '';
BEGIN
  -- Obter ID do usuário autenticado
  auth_user_id := auth.uid();
  debug_info := debug_info || 'auth_user_id: ' || COALESCE(auth_user_id::text, 'NULL') || '; ';
  
  -- Se não há usuário autenticado, retornar role padrão
  IF auth_user_id IS NULL THEN
    RAISE NOTICE 'get_current_user_role: Sem usuário autenticado, retornando role 4';
    RETURN 4; -- User role
  END IF;
  
  -- Verificar se é super admin direto por email
  IF EXISTS (
    SELECT 1 FROM auth.users 
    WHERE id = auth_user_id 
    AND email IN ('superadmin@sistema.com', 'fernando@genesisx.com.br')
  ) THEN
    RAISE NOTICE 'get_current_user_role: Super admin detectado pelo email';
    RETURN 1;
  END IF;
  
  -- Buscar role_id do cache primeiro
  SELECT role_id INTO user_role_id
  FROM public.user_cache 
  WHERE auth_user_id = auth.uid();
  
  debug_info := debug_info || 'cache_role: ' || COALESCE(user_role_id::text, 'NULL') || '; ';
  
  -- Se encontrou no cache, retornar
  IF user_role_id IS NOT NULL THEN
    RAISE NOTICE 'get_current_user_role: Role encontrado no cache: %', user_role_id;
    RETURN user_role_id;
  END IF;
  
  -- Fallback: buscar diretamente na tabela users
  SELECT u.role_id INTO user_role_id
  FROM public.users u
  INNER JOIN auth.users au ON au.email = u.email
  WHERE au.id = auth_user_id;
  
  debug_info := debug_info || 'direct_role: ' || COALESCE(user_role_id::text, 'NULL') || '; ';
  RAISE NOTICE 'get_current_user_role debug: %', debug_info;
  
  -- Se encontrou, sincronizar no cache para próximas consultas
  IF user_role_id IS NOT NULL THEN
    INSERT INTO public.user_cache (auth_user_id, user_id, role_id, company_id, email, updated_at)
    SELECT 
      auth_user_id,
      u.id,
      u.role_id,
      u.company_id,
      u.email,
      NOW()
    FROM public.users u
    INNER JOIN auth.users au ON au.email = u.email
    WHERE au.id = auth_user_id
    ON CONFLICT (auth_user_id) 
    DO UPDATE SET 
      role_id = EXCLUDED.role_id,
      updated_at = NOW();
      
    RAISE NOTICE 'get_current_user_role: Role sincronizado no cache: %', user_role_id;
  END IF;
  
  RETURN COALESCE(user_role_id, 4); -- Default: User
END;
$$;


ALTER FUNCTION "public"."get_current_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_subscription_status"("p_company_id" integer) RETURNS TABLE("status" character varying, "days_remaining" integer, "expires_at" timestamp with time zone, "subscription_name" "text", "is_blocked" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  subscription_record RECORD;
  current_status text;
  days_diff integer;
  is_blocked_manual boolean := false;
BEGIN
  -- Get active subscription data
  SELECT 
    cs.status,
    cs.expires_at,
    s.name::text as sub_name,
    cs.id as cs_id
  INTO subscription_record
  FROM public.company_subscriptions cs
  JOIN public.subscriptions s ON s.id = cs.subscription_id
  WHERE cs.company_id = p_company_id
  AND cs.status IN ('active', 'expired', 'blocked')
  ORDER BY cs.signed_at DESC
  LIMIT 1;
  
  -- If no subscription found
  IF NOT FOUND THEN
    RETURN QUERY SELECT 
      'no_subscription'::character varying,
      0,
      NULL::timestamp with time zone,
      'Sem Assinatura'::text,
      false;
    RETURN;
  END IF;
  
  -- Calculate days remaining
  days_diff := EXTRACT(DAY FROM subscription_record.expires_at - now());
  
  -- Check if manually blocked
  is_blocked_manual := (subscription_record.status = 'blocked');
  
  -- Determine status
  IF is_blocked_manual THEN
    current_status := 'blocked';
  ELSIF subscription_record.expires_at > now() THEN
    IF days_diff <= 1 THEN
      current_status := 'warning';
    ELSE
      current_status := 'active';
    END IF;
  ELSE
    current_status := 'expired';
  END IF;
  
  RETURN QUERY SELECT 
    current_status::character varying,
    days_diff,
    subscription_record.expires_at,
    subscription_record.sub_name,
    is_blocked_manual;
END;
$$;


ALTER FUNCTION "public"."get_subscription_status"("p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_subscriptions_expiring_soon"() RETURNS TABLE("id" integer, "company_id" integer, "company_name" "text", "subscription_name" "text", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    cs.id,
    cs.company_id,
    c.name::TEXT as company_name,
    s.name::TEXT as subscription_name,
    cs.expires_at
  FROM public.company_subscriptions cs
  JOIN public.companies c ON c.id = cs.company_id
  JOIN public.subscriptions s ON s.id = cs.subscription_id
  WHERE cs.status = 'active'
    AND cs.expires_at <= (now() + INTERVAL '3 days')
    AND cs.expires_at > now()
    AND cs.notify_3_days_sent = false
  ORDER BY cs.expires_at ASC
  LIMIT 100; -- Safety limit
END;
$$;


ALTER FUNCTION "public"."get_subscriptions_expiring_soon"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_affiliate_codes"() RETURNS "text"[]
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
  -- Super Admin vê todos
  IF get_current_user_role() = 1 THEN
    RETURN ARRAY(SELECT DISTINCT code FROM public.affiliate_links);
  END IF;
  
  -- Company Admin vê todos da empresa
  IF get_current_user_role() = 2 THEN
    RETURN ARRAY(
      SELECT DISTINCT code 
      FROM public.affiliate_links 
      WHERE company_id = get_current_user_company()
    );
  END IF;
  
  -- Afiliados veem apenas seus próprios códigos
  RETURN ARRAY(
    SELECT DISTINCT code 
    FROM public.affiliate_links 
    WHERE user_id = (SELECT user_id FROM public.user_cache WHERE auth_user_id = auth.uid())
    AND company_id = get_current_user_company()
  );
END;
$$;


ALTER FUNCTION "public"."get_user_affiliate_codes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_company"() RETURNS integer
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
  RETURN (SELECT company_id FROM public.user_cache WHERE auth_user_id = auth.uid());
END;
$$;


ALTER FUNCTION "public"."get_user_company"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_company_id"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN (
        SELECT company_id FROM public.users 
        WHERE id = (auth.jwt() ->> 'user_id')::integer
    );
END;
$$;


ALTER FUNCTION "public"."get_user_company_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role"() RETURNS integer
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
BEGIN
  RETURN COALESCE(
    (SELECT role_id FROM public.user_cache WHERE auth_user_id = auth.uid()),
    4 -- Role padrão: User
  );
END;
$$;


ALTER FUNCTION "public"."get_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role_id"() RETURNS integer
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    AS $$
DECLARE
  user_role_id INTEGER;
BEGIN
  -- Se é super admin, retornar 1
  IF public.is_super_admin() THEN
    RETURN 1;
  END IF;
  
  -- Buscar role_id do cache
  SELECT role_id INTO user_role_id
  FROM public.user_cache 
  WHERE auth_user_id = auth.uid();
  
  RETURN COALESCE(user_role_id, 4); -- Default: User
END;
$$;


ALTER FUNCTION "public"."get_user_role_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_commission_on_sale"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  existing_commission_id INTEGER;
BEGIN
  -- Log para debug
  RAISE NOTICE '[COMISSÃO] Trigger executado - Op: %, Venda: %, Afiliado: %, Status: %, Comissão: %', 
    TG_OP, NEW.id, NEW.affiliate_user_id, NEW.status, NEW.commission_amount;
  
  -- CASO 1: Venda confirmada com afiliado
  IF NEW.status = 'confirmed' AND NEW.affiliate_user_id IS NOT NULL AND NEW.commission_amount > 0 THEN
    
    -- Verificar se já existe comissão para esta venda
    SELECT id INTO existing_commission_id
    FROM public.affiliate_commissions_earned 
    WHERE user_id = NEW.affiliate_user_id 
    AND company_id = NEW.company_id
    AND amount = NEW.commission_amount
    AND DATE(earned_at) = DATE(NEW.sale_date)
    LIMIT 1;
    
    IF existing_commission_id IS NULL THEN
      -- Criar nova comissão
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        order_item_id,
        amount,
        status,
        earned_at,
        created_at,
        updated_at
      ) VALUES (
        NEW.affiliate_user_id,
        NEW.company_id,
        NULL,
        NEW.commission_amount,
        'pending'::commission_status,
        NEW.sale_date,
        NOW(),
        NOW()
      );
      
      RAISE NOTICE '[COMISSÃO] ✅ Nova comissão criada: R$ % para afiliado %', 
        NEW.commission_amount, NEW.affiliate_user_id;
    ELSE
      -- Atualizar comissão existente
      UPDATE public.affiliate_commissions_earned 
      SET status = 'pending'::commission_status, updated_at = NOW()
      WHERE id = existing_commission_id;
      
      RAISE NOTICE '[COMISSÃO] ✅ Comissão atualizada ID: %', existing_commission_id;
    END IF;
    
  -- CASO 2: Venda cancelada/estornada - cancelar comissões
  ELSIF NEW.status IN ('cancelled', 'refunded') AND NEW.affiliate_user_id IS NOT NULL THEN
    
    UPDATE public.affiliate_commissions_earned 
    SET status = 'cancelled'::commission_status, updated_at = NOW()
    WHERE user_id = NEW.affiliate_user_id 
    AND company_id = NEW.company_id
    AND DATE(earned_at) = DATE(NEW.sale_date)
    AND status = 'pending';
    
    RAISE NOTICE '[COMISSÃO] ❌ Comissões canceladas para venda %', NEW.id;
  END IF;
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."handle_commission_on_sale"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_commission_on_sale"() IS 'Função unificada para gerenciar comissões automaticamente quando status da venda muda';



CREATE OR REPLACE FUNCTION "public"."handle_commission_on_sale_complete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  existing_commission_id INTEGER;
  sale_info TEXT;
BEGIN
  -- Construir informação da venda para logs
  sale_info := format('Venda ID: %s | Cliente: %s | Afiliado: %s | Valor: %s | Comissão: %s | Status: %s -> %s',
    NEW.id, 
    NEW.customer_name, 
    NEW.affiliate_user_id, 
    NEW.amount, 
    NEW.commission_amount,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE 'new' END,
    NEW.status
  );
  
  RAISE NOTICE '[COMISSÃO] %s - %s', TG_OP, sale_info;
  
  -- CASO 1: Venda confirmada com afiliado e comissão
  IF NEW.status = 'confirmed' AND NEW.affiliate_user_id IS NOT NULL AND NEW.commission_amount > 0 THEN
    
    -- Verificar se já existe comissão
    SELECT id INTO existing_commission_id
    FROM public.affiliate_commissions_earned 
    WHERE user_id = NEW.affiliate_user_id 
    AND company_id = NEW.company_id
    AND amount = NEW.commission_amount
    AND DATE(earned_at) = DATE(NEW.sale_date)
    LIMIT 1;
    
    IF existing_commission_id IS NULL THEN
      -- Criar nova comissão
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        order_item_id,
        amount,
        status,
        earned_at,
        created_at,
        updated_at
      ) VALUES (
        NEW.affiliate_user_id,
        NEW.company_id,
        NULL,
        NEW.commission_amount,
        'pending'::commission_status,
        NEW.sale_date,
        NOW(),
        NOW()
      ) RETURNING id INTO existing_commission_id;
      
      RAISE NOTICE '[COMISSÃO] ✅ NOVA comissão criada ID: % para afiliado %', 
        existing_commission_id, NEW.affiliate_user_id;
    ELSE
      -- Atualizar comissão existente para pending se estava cancelada
      UPDATE public.affiliate_commissions_earned 
      SET status = 'pending'::commission_status, updated_at = NOW()
      WHERE id = existing_commission_id
      AND status != 'pending';
      
      RAISE NOTICE '[COMISSÃO] ✅ ATUALIZADA comissão existente ID: %', existing_commission_id;
    END IF;
    
  -- CASO 2: Venda cancelada/estornada - cancelar comissões
  ELSIF NEW.status IN ('cancelled', 'refunded') AND NEW.affiliate_user_id IS NOT NULL THEN
    
    -- Cancelar comissões relacionadas
    UPDATE public.affiliate_commissions_earned 
    SET status = 'cancelled'::commission_status, updated_at = NOW()
    WHERE user_id = NEW.affiliate_user_id 
    AND company_id = NEW.company_id
    AND DATE(earned_at) = DATE(NEW.sale_date)
    AND status = 'pending';
    
    GET DIAGNOSTICS existing_commission_id = ROW_COUNT;
    RAISE NOTICE '[COMISSÃO] ❌ CANCELADAS % comissões para venda %', 
      existing_commission_id, NEW.id;
      
  -- CASO 3: Status voltou para pending - manter comissões pendentes
  ELSIF NEW.status = 'pending' AND NEW.affiliate_user_id IS NOT NULL THEN
    RAISE NOTICE '[COMISSÃO] ⏳ Venda voltou para PENDING - mantendo comissões';
  
  ELSE
    RAISE NOTICE '[COMISSÃO] ⚠️ Nenhuma ação necessária para esta venda';
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_commission_on_sale_complete"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."handle_commission_on_sale_complete"() IS 'Função completa para gerenciar comissões automaticamente com logs detalhados';



CREATE OR REPLACE FUNCTION "public"."handle_commission_on_sale_with_mlm"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  existing_commission_id INTEGER;
  final_commission NUMERIC;
BEGIN
  -- Log for debug
  RAISE NOTICE '[COMMISSION+MLM] Processing sale ID: %, Status: % -> %', 
    NEW.id, 
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status ELSE 'new' END,
    NEW.status;
  
  -- CASE 1: Sale confirmed with affiliate and commission
  IF NEW.status = 'confirmed' AND NEW.affiliate_user_id IS NOT NULL AND NEW.commission_amount > 0 THEN
    
    -- Create/update direct commission (existing logic)
    SELECT id INTO existing_commission_id
    FROM public.affiliate_commissions_earned 
    WHERE user_id = NEW.affiliate_user_id 
    AND company_id = NEW.company_id
    AND amount = NEW.commission_amount
    AND DATE(earned_at) = DATE(NEW.sale_date)
    AND commission_type = 'direct'
    LIMIT 1;
    
    IF existing_commission_id IS NULL THEN
      -- Create new direct commission
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        source_sale_id,
        amount,
        commission_type,
        level,
        status,
        earned_at,
        created_at,
        updated_at
      ) VALUES (
        NEW.affiliate_user_id,
        NEW.company_id,
        NEW.id,
        NEW.commission_amount,
        'direct',
        1,
        'pending'::commission_status,
        NEW.sale_date,
        NOW(),
        NOW()
      );
      
      RAISE NOTICE '[COMMISSION+MLM] ✅ Direct commission created: R$ % for affiliate %', 
        NEW.commission_amount, NEW.affiliate_user_id;
    END IF;
    
    -- Create MLM override commissions for upline
    PERFORM public.create_mlm_override_commissions(
      NEW.id,
      NEW.affiliate_user_id,
      NEW.company_id,
      NEW.amount,
      NEW.sale_date
    );
    
  -- CASE 2: Sale cancelled/refunded - cancel all commissions
  ELSIF NEW.status IN ('cancelled', 'refunded') AND NEW.affiliate_user_id IS NOT NULL THEN
    
    -- Cancel direct commission
    UPDATE public.affiliate_commissions_earned 
    SET status = 'cancelled'::commission_status, updated_at = NOW()
    WHERE user_id = NEW.affiliate_user_id 
    AND company_id = NEW.company_id
    AND source_sale_id = NEW.id
    AND commission_type = 'direct'
    AND status = 'pending';
    
    -- Cancel MLM override commissions
    PERFORM public.cancel_mlm_override_commissions(NEW.id);
    
    RAISE NOTICE '[COMMISSION+MLM] ❌ All commissions cancelled for sale %', NEW.id;
  END IF;
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."handle_commission_on_sale_with_mlm"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_super_admin"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.users 
        WHERE id = (auth.jwt() ->> 'user_id')::integer 
        AND role = 1
    );
END;
$$;


ALTER FUNCTION "public"."is_super_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."manually_block_subscription"("p_company_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_email TEXT;
  is_superadmin BOOLEAN := false;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  current_user_email := (SELECT email FROM auth.users WHERE id = auth.uid());
  
  IF current_user_email = 'superadmin@sistema.com' THEN
    is_superadmin := true;
  END IF;
  
  -- Se não for SuperAdmin, verificar no cache
  IF NOT is_superadmin THEN
    SELECT (role_id = 1) INTO is_superadmin
    FROM public.user_cache 
    WHERE auth_user_id = auth.uid();
  END IF;
  
  -- Só SuperAdmin pode executar esta função
  IF NOT COALESCE(is_superadmin, false) THEN
    RAISE EXCEPTION 'Apenas SuperAdmin pode bloquear assinaturas manualmente';
  END IF;

  -- Atualizar o status da assinatura para 'blocked'
  UPDATE public.company_subscriptions 
  SET status = 'blocked'::subscription_status,
      updated_at = NOW()
  WHERE company_id = p_company_id;
  
  -- Verificar se a atualização foi bem-sucedida
  IF FOUND THEN
    RAISE NOTICE 'Assinatura da empresa % bloqueada manualmente pelo SuperAdmin %', p_company_id, current_user_email;
    RETURN true;
  ELSE
    RAISE NOTICE 'Nenhuma assinatura encontrada para empresa %', p_company_id;
    RETURN false;
  END IF;
END;
$$;


ALTER FUNCTION "public"."manually_block_subscription"("p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_commission_as_paid"("p_commission_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Atualizar comissão para pago
  UPDATE public.affiliate_commissions_earned 
  SET status = 'paid'::commission_status, updated_at = NOW()
  WHERE id = p_commission_id;
  
  IF FOUND THEN
    RAISE NOTICE 'Comissão % marcada como paga', p_commission_id;
    RETURN TRUE;
  ELSE
    RAISE NOTICE 'Comissão % não encontrada', p_commission_id;
    RETURN FALSE;
  END IF;
END;
$$;


ALTER FUNCTION "public"."mark_commission_as_paid"("p_commission_id" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."mark_commission_as_paid"("p_commission_id" integer) IS 'Função para marcar uma comissão específica como paga';



CREATE OR REPLACE FUNCTION "public"."mark_expired_subscriptions"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  expired_count INTEGER;
  company_ids INTEGER[];
BEGIN
  -- Get company IDs that will be expired
  SELECT ARRAY_AGG(company_id)
  INTO company_ids
  FROM public.company_subscriptions
  WHERE status = 'active' AND expires_at <= NOW();
  
  -- Mark subscriptions as expired
  UPDATE public.company_subscriptions
  SET status = 'expired', updated_at = NOW()
  WHERE status = 'active' AND expires_at <= NOW();
  
  GET DIAGNOSTICS expired_count = ROW_COUNT;
  
  -- Clear subscription_id from companies table for expired subscriptions
  IF company_ids IS NOT NULL AND array_length(company_ids, 1) > 0 THEN
    UPDATE public.companies
    SET subscription_id = NULL
    WHERE id = ANY(company_ids);
    
    RAISE NOTICE '[EXPIRATION] Marked % subscriptions as expired and cleared % company subscription_ids', 
      expired_count, array_length(company_ids, 1);
  ELSE
    RAISE NOTICE '[EXPIRATION] No subscriptions to expire';
  END IF;
  
  RETURN expired_count;
END;
$$;


ALTER FUNCTION "public"."mark_expired_subscriptions"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_subscription_as_paid"("p_company_id" integer, "p_new_expires_at" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_subscription RECORD;
  new_expires_date TIMESTAMP WITH TIME ZONE;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  IF NOT EXISTS (
    SELECT 1 FROM user_cache 
    WHERE auth_user_id = auth.uid() AND role_id = 1
  ) THEN
    RAISE EXCEPTION 'Apenas Super Admin pode marcar assinaturas como pagas';
  END IF;

  -- Buscar assinatura atual da empresa
  SELECT * INTO current_subscription
  FROM company_subscriptions cs
  WHERE cs.company_id = p_company_id
  ORDER BY cs.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nenhuma assinatura encontrada para a empresa %', p_company_id;
  END IF;

  -- Definir nova data de expiração
  IF p_new_expires_at IS NOT NULL THEN
    new_expires_date := p_new_expires_at;
  ELSE
    -- Buscar duração da assinatura
    SELECT 
      CASE s.duration_unit
        WHEN 'minutes' THEN NOW() + (s.duration_value || ' minutes')::INTERVAL
        WHEN 'hours' THEN NOW() + (s.duration_value || ' hours')::INTERVAL  
        WHEN 'days' THEN NOW() + (s.duration_value || ' days')::INTERVAL
        WHEN 'months' THEN NOW() + (s.duration_value || ' months')::INTERVAL
        ELSE NOW() + INTERVAL '30 days'
      END INTO new_expires_date
    FROM subscriptions s
    WHERE s.id = current_subscription.subscription_id;
  END IF;

  -- Atualizar assinatura para ativa
  UPDATE company_subscriptions 
  SET 
    status = 'active',
    expires_at = new_expires_date,
    updated_at = NOW()
  WHERE company_id = p_company_id
  AND id = current_subscription.id;

  RAISE NOTICE 'Assinatura da empresa % reativada até %', p_company_id, new_expires_date;
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."mark_subscription_as_paid"("p_company_id" integer, "p_new_expires_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_commission_earned"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
BEGIN
  PERFORM public.create_notification(
    NEW.user_id,
    NEW.company_id,
    'Comissão Calculada',
    'Nova comissão de R$ ' || NEW.amount::text || ' foi calculada para você',
    'success',
    jsonb_build_object('commission_id', NEW.id, 'amount', NEW.amount)
  );
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."notify_commission_earned"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_new_sale"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
DECLARE
  admin_user_id INTEGER;
BEGIN
  -- Buscar admin da empresa
  SELECT id INTO admin_user_id
  FROM public.users
  WHERE company_id = NEW.company_id
  AND role_id = 2 -- Admin role
  LIMIT 1;
  
  IF admin_user_id IS NOT NULL THEN
    PERFORM public.create_notification(
      admin_user_id,
      NEW.company_id,
      'Nova Venda Registrada',
      'Uma nova venda foi registrada no valor de R$ ' || NEW.amount::text || ' para o produto ' || NEW.product_name,
      'info',
      jsonb_build_object('sale_id', NEW.id, 'amount', NEW.amount, 'product_name', NEW.product_name)
    );
  END IF;
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."notify_new_sale"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_payment_processed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
BEGIN
  -- Notificar quando pagamento é marcado como processado
  IF NEW.status = 'paid' AND OLD.status != 'paid' THEN
    PERFORM public.create_notification(
      NEW.user_id,
      NEW.company_id,
      'Pagamento Processado',
      'Seu pagamento de R$ ' || NEW.amount::text || ' foi processado com sucesso',
      'success',
      jsonb_build_object('payment_id', NEW.id, 'amount', NEW.amount)
    );
  END IF;
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."notify_payment_processed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_sale_confirmed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $_$
BEGIN
  -- Só notificar quando status muda para confirmed e há afiliado
  IF NEW.status = 'confirmed' AND OLD.status != 'confirmed' AND NEW.affiliate_user_id IS NOT NULL THEN
    PERFORM public.create_notification(
      NEW.affiliate_user_id,
      NEW.company_id,
      'Venda Confirmada!',
      'Sua venda do produto ' || NEW.product_name || ' foi confirmada! Comissão: R$ ' || COALESCE(NEW.commission_amount, 0)::text,
      'success',
      jsonb_build_object('sale_id', NEW.id, 'commission_amount', NEW.commission_amount, 'product_name', NEW.product_name)
    );
  END IF;
  
  RETURN NEW;
END;
$_$;


ALTER FUNCTION "public"."notify_sale_confirmed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_commissions"("p_company_id" integer DEFAULT NULL::integer) RETURNS TABLE("sale_id" integer, "old_commission" numeric, "new_commission" numeric, "difference" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  sale_record RECORD;
  new_comm NUMERIC;
BEGIN
  FOR sale_record IN 
    SELECT s.id, s.product_name, s.amount, s.commission_amount, s.company_id, s.affiliate_user_id
    FROM public.sales s
    WHERE (p_company_id IS NULL OR s.company_id = p_company_id)
    AND s.affiliate_user_id IS NOT NULL
  LOOP
    -- Calcular nova comissão
    new_comm := public.calculate_product_commission(
      sale_record.product_name,
      sale_record.amount,
      sale_record.company_id,
      NULL -- Forçar cálculo automático
    );
    
    RETURN QUERY SELECT 
      sale_record.id,
      sale_record.commission_amount,
      new_comm,
      new_comm - sale_record.commission_amount;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."recalculate_commissions"("p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_affiliate_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Validate no circular referral
  IF NOT public.validate_no_circular_referral(p_sponsor_user_id, p_referred_user_id, p_company_id) THEN
    RAISE EXCEPTION 'Circular referral detected - affiliate cannot sponsor someone in their upline';
  END IF;
  
  -- Insert referral relationship
  INSERT INTO public.affiliate_referrals (
    sponsor_user_id,
    referred_user_id,
    company_id,
    status
  ) VALUES (
    p_sponsor_user_id,
    p_referred_user_id,
    p_company_id,
    'active'
  );
  
  RAISE NOTICE '[MLM] Referral registered: Sponsor % -> Referred %', p_sponsor_user_id, p_referred_user_id;
  RETURN TRUE;
  
EXCEPTION WHEN unique_violation THEN
  RAISE NOTICE '[MLM] Referral already exists for user % in company %', p_referred_user_id, p_company_id;
  RETURN FALSE;
END;
$$;


ALTER FUNCTION "public"."register_affiliate_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_lead_with_journey"("p_name" "text", "p_email" "text", "p_phone" "text", "p_product_id" integer, "p_product_name" "text", "p_affiliate_code" "text", "p_company_id" integer, "p_ip_address" "text" DEFAULT NULL::"text", "p_user_agent" "text" DEFAULT NULL::"text", "p_referrer" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    lead_id INTEGER;
    affiliate_user_id INTEGER;
    session_id VARCHAR(100);
BEGIN
    -- Gerar session_id único
    session_id := 'lead_' || extract(epoch from now()) || '_' || substr(md5(random()::text), 1, 8);
    
    -- Buscar user_id do afiliado
    SELECT al.user_id INTO affiliate_user_id
    FROM public.affiliate_links al
    WHERE al.code = p_affiliate_code 
    AND al.company_id = p_company_id
    LIMIT 1;
    
    -- Inserir lead
    INSERT INTO public.leads (
        name, email, phone, product_id, product_name, 
        affiliate_code, affiliate_user_id, company_id,
        ip_address, user_agent, referrer,
        created_at, updated_at
    ) VALUES (
        p_name, p_email, p_phone, p_product_id, p_product_name,
        p_affiliate_code, affiliate_user_id, p_company_id,
        p_ip_address::inet, p_user_agent, p_referrer,
        NOW(), NOW()
    ) RETURNING id INTO lead_id;
    
    -- Registrar eventos da jornada
    INSERT INTO public.engagement_events (
        session_id, affiliate_code, event_type, timestamp, 
        metadata, ip_address, user_agent, company_id
    ) VALUES 
    (session_id, p_affiliate_code, 'access', NOW() - INTERVAL '5 minutes', 
     jsonb_build_object('lead_id', lead_id, 'step', 'access'), 
     p_ip_address::inet, p_user_agent, p_company_id),
    (session_id, p_affiliate_code, 'engagement', NOW() - INTERVAL '3 minutes', 
     jsonb_build_object('lead_id', lead_id, 'step', 'engagement'), 
     p_ip_address::inet, p_user_agent, p_company_id),
    (session_id, p_affiliate_code, 'form_start', NOW() - INTERVAL '2 minutes', 
     jsonb_build_object('lead_id', lead_id, 'step', 'interest'), 
     p_ip_address::inet, p_user_agent, p_company_id),
    (session_id, p_affiliate_code, 'intention_cta', NOW() - INTERVAL '1 minute', 
     jsonb_build_object('lead_id', lead_id, 'step', 'intention'), 
     p_ip_address::inet, p_user_agent, p_company_id),
    (session_id, p_affiliate_code, 'negotiation_start', NOW(), 
     jsonb_build_object('lead_id', lead_id, 'step', 'negotiation'), 
     p_ip_address::inet, p_user_agent, p_company_id);
    
    -- Criar sessão ativa
    INSERT INTO public.active_sessions (
        session_id, affiliate_code, company_id, start_time, 
        last_activity, total_active_time, is_active,
        ip_address, user_agent, referrer
    ) VALUES (
        session_id, p_affiliate_code, p_company_id, NOW() - INTERVAL '5 minutes',
        NOW(), 300, false, p_ip_address::inet, p_user_agent, p_referrer
    );
    
    RETURN lead_id;
END;
$$;


ALTER FUNCTION "public"."register_lead_with_journey"("p_name" "text", "p_email" "text", "p_phone" "text", "p_product_id" integer, "p_product_name" "text", "p_affiliate_code" "text", "p_company_id" integer, "p_ip_address" "text", "p_user_agent" "text", "p_referrer" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_lead_with_journey"("p_name" character varying, "p_email" character varying, "p_phone" character varying, "p_product_id" integer, "p_product_name" character varying, "p_affiliate_code" character varying, "p_company_id" integer, "p_ip_address" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_referrer" "text" DEFAULT NULL::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_lead_id INTEGER;
  v_affiliate_user_id INTEGER;
  v_affiliate_link_id INTEGER;
BEGIN
  -- Buscar dados do afiliado se código fornecido
  IF p_affiliate_code IS NOT NULL THEN
    SELECT al.user_id, al.id
    INTO v_affiliate_user_id, v_affiliate_link_id
    FROM affiliate_links al
    WHERE al.code = p_affiliate_code
    AND al.company_id = p_company_id;
  END IF;
  
  -- Inserir lead
  INSERT INTO public.leads (
    name, email, phone, product_id, product_name,
    affiliate_code, affiliate_user_id, company_id,
    ip_address, user_agent, referrer
  ) VALUES (
    p_name, p_email, p_phone, p_product_id, p_product_name,
    p_affiliate_code, v_affiliate_user_id, p_company_id,
    p_ip_address, p_user_agent, p_referrer
  )
  RETURNING id INTO v_lead_id;
  
  -- Se há afiliado, registrar como interesse na jornada
  IF v_affiliate_link_id IS NOT NULL THEN
    -- Atualizar clicks existentes para marcar interesse
    UPDATE affiliate_link_clicks 
    SET user_agent = COALESCE(user_agent, '') || ' [LEAD_CAPTURED]'
    WHERE affiliate_link_id = v_affiliate_link_id
    AND ip_address = p_ip_address
    AND clicked_at >= NOW() - INTERVAL '24 hours';
  END IF;
  
  RETURN v_lead_id;
END;
$$;


ALTER FUNCTION "public"."register_lead_with_journey"("p_name" character varying, "p_email" character varying, "p_phone" character varying, "p_product_id" integer, "p_product_name" character varying, "p_affiliate_code" character varying, "p_company_id" integer, "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text" DEFAULT NULL::"text", "p_ip_address" "inet" DEFAULT NULL::"inet") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  INSERT INTO subscription_notification_history (
    company_id,
    notification_type,
    user_session,
    ip_address
  ) VALUES (
    p_company_id,
    p_notification_type,
    p_user_session,
    p_ip_address
  );
  
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;


ALTER FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "inet") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text" DEFAULT NULL::"text", "p_ip_address" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  INSERT INTO subscription_notifications_history (
    company_id,
    notification_type,
    user_session,
    ip_address,
    shown_at
  ) VALUES (
    p_company_id,
    p_notification_type,
    p_user_session,
    p_ip_address::inet,
    now()
  );
  
  RAISE NOTICE '[NOTIFICATION] Registrada exibição - empresa: %, tipo: %, sessão: %', 
    p_company_id, p_notification_type, p_user_session;
  
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '[NOTIFICATION] Erro ao registrar: %', SQLERRM;
  RETURN false;
END;
$$;


ALTER FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."should_show_notification"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  settings_record RECORD;
  frequency_hours integer;
  max_shows_per_day integer;
  last_shown_time timestamp with time zone;
  today_count integer;
BEGIN
  -- Buscar configurações
  SELECT * INTO settings_record 
  FROM subscription_notification_settings 
  WHERE id = 1;
  
  IF NOT FOUND THEN
    RAISE NOTICE '[NOTIFICATION] Configurações não encontradas, permitindo exibição';
    RETURN true;
  END IF;
  
  -- Determinar configurações baseado no tipo
  CASE p_notification_type
    WHEN 'warning' THEN
      frequency_hours := settings_record.warning_show_frequency_hours;
      max_shows_per_day := settings_record.warning_max_shows_per_day;
    WHEN 'expired' THEN  
      frequency_hours := settings_record.expired_show_frequency_hours;
      max_shows_per_day := settings_record.expired_max_shows_per_day;
    WHEN 'blocked' THEN
      frequency_hours := settings_record.blocked_show_frequency_hours;
      max_shows_per_day := settings_record.blocked_max_shows_per_day;
    ELSE
      RAISE NOTICE '[NOTIFICATION] Tipo inválido: %, permitindo exibição', p_notification_type;
      RETURN true;
  END CASE;
  
  -- Verificar última exibição para este usuário/sessão
  SELECT shown_at INTO last_shown_time
  FROM subscription_notifications_history
  WHERE company_id = p_company_id
    AND notification_type = p_notification_type
    AND (p_user_session IS NULL OR user_session = p_user_session)
  ORDER BY shown_at DESC
  LIMIT 1;
  
  -- Se nunca foi mostrada, pode exibir
  IF last_shown_time IS NULL THEN
    RAISE NOTICE '[NOTIFICATION] Primeira exibição para empresa % tipo %', p_company_id, p_notification_type;
    RETURN true;
  END IF;
  
  -- Verificar intervalo de frequência
  IF last_shown_time + (frequency_hours || ' hours')::interval > now() THEN
    RAISE NOTICE '[NOTIFICATION] Muito cedo para exibir - última em %, próxima em %', 
      last_shown_time, last_shown_time + (frequency_hours || ' hours')::interval;
    RETURN false;
  END IF;
  
  -- Verificar limite diário
  SELECT COUNT(*) INTO today_count
  FROM subscription_notifications_history
  WHERE company_id = p_company_id
    AND notification_type = p_notification_type
    AND shown_at >= date_trunc('day', now())
    AND (p_user_session IS NULL OR user_session = p_user_session);
  
  IF today_count >= max_shows_per_day THEN
    RAISE NOTICE '[NOTIFICATION] Limite diário atingido: %/% para tipo %', 
      today_count, max_shows_per_day, p_notification_type;
    RETURN false;
  END IF;
  
  RAISE NOTICE '[NOTIFICATION] Permitindo exibição - empresa: %, tipo: %, count hoje: %/%', 
    p_company_id, p_notification_type, today_count, max_shows_per_day;
  RETURN true;
END;
$$;


ALTER FUNCTION "public"."should_show_notification"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_missing_user_cache"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Sincronizar usuários que existem no auth mas não no cache
  INSERT INTO public.user_cache (auth_user_id, user_id, role_id, company_id, email, updated_at)
  SELECT 
    au.id as auth_user_id,
    u.id as user_id,
    u.role_id,
    u.company_id,
    u.email,
    NOW()
  FROM auth.users au
  INNER JOIN public.users u ON u.email = au.email
  LEFT JOIN public.user_cache uc ON uc.auth_user_id = au.id
  WHERE uc.auth_user_id IS NULL
  ON CONFLICT (auth_user_id) DO NOTHING;
  
  RAISE NOTICE 'Sincronização de user_cache concluída';
END;
$$;


ALTER FUNCTION "public"."sync_missing_user_cache"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_pending_commissions"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  sync_count INTEGER := 0;
  sale_record RECORD;
BEGIN
  RAISE NOTICE '[SYNC] Iniciando sincronização de comissões perdidas...';
  
  -- Buscar vendas confirmadas sem comissão
  FOR sale_record IN 
    SELECT s.* 
    FROM public.sales s
    LEFT JOIN public.affiliate_commissions_earned ace ON (
      ace.user_id = s.affiliate_user_id 
      AND ace.company_id = s.company_id
      AND ace.amount = s.commission_amount
      AND DATE(ace.earned_at) = DATE(s.sale_date)
    )
    WHERE s.status = 'confirmed'
    AND s.affiliate_user_id IS NOT NULL
    AND s.commission_amount > 0
    AND ace.id IS NULL
  LOOP
    -- Criar comissão perdida
    INSERT INTO public.affiliate_commissions_earned (
      user_id,
      company_id,
      order_item_id,
      amount,
      status,
      earned_at,
      created_at,
      updated_at
    ) VALUES (
      sale_record.affiliate_user_id,
      sale_record.company_id,
      NULL,
      sale_record.commission_amount,
      'pending'::commission_status,
      sale_record.sale_date,
      NOW(),
      NOW()
    );
    
    sync_count := sync_count + 1;
    RAISE NOTICE '[SYNC] ✅ Comissão sincronizada: Venda % -> Afiliado %', 
      sale_record.id, sale_record.affiliate_user_id;
  END LOOP;
  
  RAISE NOTICE '[SYNC] Concluído. % comissões sincronizadas', sync_count;
  RETURN sync_count;
END;
$$;


ALTER FUNCTION "public"."sync_pending_commissions"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_pending_commissions"() IS 'Sincroniza comissões que não foram criadas automaticamente pelos triggers';



CREATE OR REPLACE FUNCTION "public"."sync_pending_commissions_complete"() RETURNS TABLE("vendas_processadas" integer, "comissoes_criadas" integer, "comissoes_atualizadas" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  sync_created INTEGER := 0;
  sync_updated INTEGER := 0;
  sync_processed INTEGER := 0;
  sale_record RECORD;
  existing_commission_id INTEGER;
BEGIN
  RAISE NOTICE '[SYNC] === INICIANDO SINCRONIZAÇÃO COMPLETA ===';
  
  -- Processar todas as vendas confirmadas com afiliado
  FOR sale_record IN 
    SELECT 
      s.id,
      s.affiliate_user_id,
      s.company_id,
      s.commission_amount,
      s.sale_date,
      s.customer_name,
      s.status
    FROM public.sales s
    WHERE s.status = 'confirmed'
    AND s.affiliate_user_id IS NOT NULL
    AND s.commission_amount > 0
    ORDER BY s.sale_date DESC
  LOOP
    sync_processed := sync_processed + 1;
    
    -- Verificar se já existe comissão
    SELECT id INTO existing_commission_id
    FROM public.affiliate_commissions_earned 
    WHERE user_id = sale_record.affiliate_user_id 
    AND company_id = sale_record.company_id
    AND amount = sale_record.commission_amount
    AND DATE(earned_at) = DATE(sale_record.sale_date);
    
    IF existing_commission_id IS NULL THEN
      -- Criar comissão perdida
      INSERT INTO public.affiliate_commissions_earned (
        user_id,
        company_id,
        order_item_id,
        amount,
        status,
        earned_at,
        created_at,
        updated_at
      ) VALUES (
        sale_record.affiliate_user_id,
        sale_record.company_id,
        NULL,
        sale_record.commission_amount,
        'pending'::commission_status,
        sale_record.sale_date,
        NOW(),
        NOW()
      );
      
      sync_created := sync_created + 1;
      RAISE NOTICE '[SYNC] ✅ CRIADA comissão para venda % (cliente: %)', 
        sale_record.id, sale_record.customer_name;
    ELSE
      -- Verificar se precisa atualizar status
      UPDATE public.affiliate_commissions_earned 
      SET status = 'pending'::commission_status, updated_at = NOW()
      WHERE id = existing_commission_id 
      AND status != 'pending';
      
      IF FOUND THEN
        sync_updated := sync_updated + 1;
        RAISE NOTICE '[SYNC] 🔄 ATUALIZADA comissão ID % para pending', existing_commission_id;
      END IF;
    END IF;
  END LOOP;
  
  RAISE NOTICE '[SYNC] === CONCLUÍDO ===';
  RAISE NOTICE '[SYNC] Vendas processadas: %', sync_processed;
  RAISE NOTICE '[SYNC] Comissões criadas: %', sync_created;
  RAISE NOTICE '[SYNC] Comissões atualizadas: %', sync_updated;
  
  RETURN QUERY SELECT sync_processed, sync_created, sync_updated;
END;
$$;


ALTER FUNCTION "public"."sync_pending_commissions_complete"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."sync_pending_commissions_complete"() IS 'Função para sincronizar e corrigir comissões perdidas com relatório detalhado';



CREATE OR REPLACE FUNCTION "public"."sync_user_cache"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Inserir ou atualizar cache do usuário
  INSERT INTO public.user_cache (auth_user_id, user_id, role_id, company_id, email, updated_at)
  SELECT 
    au.id as auth_user_id,
    NEW.id as user_id,
    NEW.role_id,
    NEW.company_id,
    NEW.email,
    NOW()
  FROM auth.users au
  WHERE au.email = NEW.email
  ON CONFLICT (auth_user_id) 
  DO UPDATE SET 
    user_id = EXCLUDED.user_id,
    role_id = EXCLUDED.role_id,
    company_id = EXCLUDED.company_id,
    email = EXCLUDED.email,
    updated_at = NOW();
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."sync_user_cache"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."track_affiliate_click"("p_affiliate_code" "text", "p_ip_address" "inet" DEFAULT NULL::"inet", "p_user_agent" "text" DEFAULT NULL::"text", "p_referrer" "text" DEFAULT NULL::"text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_link_id INTEGER;
  v_user_id INTEGER;
  v_company_id INTEGER;
BEGIN
  -- Buscar informações do link de afiliado
  SELECT al.id, al.user_id, al.company_id
  INTO v_link_id, v_user_id, v_company_id
  FROM public.affiliate_links al
  WHERE al.code = p_affiliate_code;
  
  -- Se o link não existir, retornar false
  IF v_link_id IS NULL THEN
    RETURN FALSE;
  END IF;
  
  -- Registrar o click
  INSERT INTO public.affiliate_link_clicks (
    affiliate_link_id,
    user_id,
    company_id,
    ip_address,
    user_agent,
    referrer
  ) VALUES (
    v_link_id,
    v_user_id,
    v_company_id,
    p_ip_address,
    p_user_agent,
    p_referrer
  );
  
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."track_affiliate_click"("p_affiliate_code" "text", "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."track_affiliate_conversion"("p_affiliate_code" "text", "p_sale_id" integer, "p_commission_amount" numeric DEFAULT 0) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_link_id INTEGER;
  v_user_id INTEGER;
  v_company_id INTEGER;
BEGIN
  -- Buscar informações do link de afiliado
  SELECT al.id, al.user_id, al.company_id
  INTO v_link_id, v_user_id, v_company_id
  FROM public.affiliate_links al
  WHERE al.code = p_affiliate_code;
  
  -- Se o link não existir, retornar false
  IF v_link_id IS NULL THEN
    RETURN FALSE;
  END IF;
  
  -- Registrar a conversão
  INSERT INTO public.affiliate_conversions (
    affiliate_link_id,
    user_id,
    company_id,
    sale_id,
    commission_amount
  ) VALUES (
    v_link_id,
    v_user_id,
    v_company_id,
    p_sale_id,
    p_commission_amount
  );
  
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."track_affiliate_conversion"("p_affiliate_code" "text", "p_sale_id" integer, "p_commission_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ultimate_force_delete_user"("p_user_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_email TEXT;
  is_superadmin BOOLEAN := false;
BEGIN
  -- Verificar se quem está executando é SuperAdmin
  current_user_email := (SELECT email FROM auth.users WHERE id = auth.uid());
  
  IF current_user_email = 'superadmin@sistema.com' THEN
    is_superadmin := true;
  END IF;
  
  -- Se não for SuperAdmin, verificar no cache
  IF NOT is_superadmin THEN
    SELECT (role_id = 1) INTO is_superadmin
    FROM public.user_cache 
    WHERE auth_user_id = auth.uid();
  END IF;
  
  -- Só SuperAdmin pode executar esta função
  IF NOT COALESCE(is_superadmin, false) THEN
    RAISE EXCEPTION 'Apenas SuperAdmin pode executar deleção ultimate de usuários';
  END IF;

  -- Log da operação
  RAISE NOTICE 'SuperAdmin % iniciando deleção ULTIMATE do usuário %', current_user_email, p_user_id;

  BEGIN
    -- ETAPA 1: Deletar dados dependentes (ao invés de nullificar)
    -- Deletar payments onde o usuário é afiliado
    DELETE FROM public.payments WHERE affiliate_user_id = p_user_id;
    RAISE NOTICE 'Deletados payments do usuário %', p_user_id;
    
    -- Deletar comissões
    DELETE FROM public.affiliate_commissions_earned WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletadas comissões do usuário %', p_user_id;
    
    -- Deletar pagamentos de afiliado
    DELETE FROM public.affiliate_payments WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletados affiliate_payments do usuário %', p_user_id;
    
    -- Deletar conversões
    DELETE FROM public.affiliate_conversions WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletadas conversões do usuário %', p_user_id;
    
    -- Deletar clicks de links
    DELETE FROM public.affiliate_link_clicks WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletados clicks do usuário %', p_user_id;
    
    -- Deletar links de afiliado
    DELETE FROM public.affiliate_links WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletados affiliate_links do usuário %', p_user_id;
    
    -- Deletar referrals como sponsor ou referred
    DELETE FROM public.affiliate_referrals 
    WHERE sponsor_user_id = p_user_id OR referred_user_id = p_user_id;
    RAISE NOTICE 'Deletados referrals do usuário %', p_user_id;
    
    -- Deletar leads onde é afiliado
    DELETE FROM public.leads WHERE affiliate_user_id = p_user_id;
    RAISE NOTICE 'Deletados leads do usuário %', p_user_id;
    
    -- Deletar vendas onde é afiliado
    DELETE FROM public.sales WHERE affiliate_user_id = p_user_id;
    RAISE NOTICE 'Deletadas sales do usuário %', p_user_id;
    
    -- Deletar orders onde é customer ou affiliate
    DELETE FROM public.orders WHERE customer_user_id = p_user_id OR affiliate_user_id = p_user_id;
    RAISE NOTICE 'Deletadas orders do usuário %', p_user_id;
    
    -- Deletar cupons do afiliado
    DELETE FROM public.coupons WHERE affiliate_user_id = p_user_id;
    RAISE NOTICE 'Deletados cupons do usuário %', p_user_id;
    
    -- Deletar withdrawal requests
    DELETE FROM public.withdrawal_requests WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletados withdrawal_requests do usuário %', p_user_id;
    
    -- Deletar notificações
    DELETE FROM public.notifications WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletadas notificações do usuário %', p_user_id;
    
    -- Deletar dados de perfil do afiliado
    DELETE FROM public.affiliate_profiles WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_addresses WHERE user_id = p_user_id;
    DELETE FROM public.affiliate_bank_data WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletados dados de perfil do usuário %', p_user_id;
    
    -- ETAPA 2: Deletar cache do usuário
    DELETE FROM public.user_cache WHERE user_id = p_user_id;
    RAISE NOTICE 'Deletado cache do usuário %', p_user_id;
    
    -- ETAPA 3: Finalmente deletar o usuário
    DELETE FROM public.users WHERE id = p_user_id;
    
    -- Verificar se realmente foi deletado
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_user_id) THEN
      RAISE NOTICE 'SUCESSO ULTIMATE: Usuário % foi COMPLETAMENTE ANIQUILADO pelo SuperAdmin %', p_user_id, current_user_email;
      RETURN true;
    ELSE
      RAISE EXCEPTION 'FALHA ULTIMATE: Usuário % ainda existe após tentativa de deleção', p_user_id;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Erro detectado durante deleção ultimate: %', SQLERRM;
    RAISE EXCEPTION 'Falha na deleção ultimate do usuário %: %', p_user_id, SQLERRM;
    RETURN false;
  END;
END;
$$;


ALTER FUNCTION "public"."ultimate_force_delete_user"("p_user_id" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."ultimate_force_delete_user"("p_user_id" integer) IS 'Função ULTIMATE para deleção completa e definitiva de usuários pelo SuperAdmin - IGNORA TODAS AS DEPENDÊNCIAS';



CREATE OR REPLACE FUNCTION "public"."update_affiliate_invitations_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_affiliate_invitations_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_company_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_company_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_company_subscriptions_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_company_subscriptions_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_coupon_usage"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  coupon_record RECORD;
BEGIN
  -- Log para debug
  RAISE NOTICE 'Verificando cupom para venda ID: %, Cupom: %, Company: %', 
    NEW.id, NEW.coupon_code, NEW.company_id;
  
  -- Verificar se a venda tem um cupom associado
  IF NEW.coupon_code IS NOT NULL AND NEW.coupon_code != '' THEN
    -- Buscar o cupom para verificar se está ativo e dentro do limite
    SELECT * INTO coupon_record
    FROM public.coupons 
    WHERE code = NEW.coupon_code 
    AND company_id = NEW.company_id;
    
    IF FOUND THEN
      -- Verificar se o cupom está ativo
      IF NOT coupon_record.active THEN
        RAISE EXCEPTION 'Cupom % está inativo e não pode ser usado', NEW.coupon_code;
      END IF;
      
      -- Verificar se ainda não atingiu o limite
      IF coupon_record.max_uses IS NOT NULL AND 
         COALESCE(coupon_record.used_count, 0) >= coupon_record.max_uses THEN
        RAISE EXCEPTION 'Cupom % já atingiu o limite máximo de % usos', 
          NEW.coupon_code, coupon_record.max_uses;
      END IF;
      
      -- Atualizar o contador de uso do cupom
      UPDATE public.coupons 
      SET used_count = COALESCE(used_count, 0) + 1,
          updated_at = NOW()
      WHERE code = NEW.coupon_code 
      AND company_id = NEW.company_id;
      
      RAISE NOTICE 'Cupom % incrementado com sucesso para company_id %', NEW.coupon_code, NEW.company_id;
    ELSE
      RAISE EXCEPTION 'Cupom % não encontrado para company_id %', NEW.coupon_code, NEW.company_id;
    END IF;
  ELSE
    RAISE NOTICE 'Venda sem cupom associado';
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_coupon_usage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_leads_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_leads_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_platform_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_platform_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_product_discount_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_product_discount_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_sales_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_sales_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_stock_on_sale"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  product_record RECORD;
BEGIN
  -- Buscar informações do produto baseado no nome (já que sales não tem product_id)
  SELECT p.id, p.stock_quantity, p.unlimited_stock 
  INTO product_record
  FROM public.products p
  WHERE p.name = NEW.product_name 
  AND p.company_id = NEW.company_id
  LIMIT 1;
  
  -- Se encontrou o produto e não tem estoque ilimitado
  IF FOUND AND NOT product_record.unlimited_stock THEN
    -- Verificar se tem estoque disponível
    IF product_record.stock_quantity <= 0 THEN
      RAISE EXCEPTION 'Produto % sem estoque disponível', NEW.product_name;
    END IF;
    
    -- Decrementar estoque
    UPDATE public.products 
    SET stock_quantity = stock_quantity - 1,
        updated_at = NOW()
    WHERE id = product_record.id;
    
    RAISE NOTICE 'Estoque do produto % decrementado. Novo estoque: %', 
      NEW.product_name, (product_record.stock_quantity - 1);
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_stock_on_sale"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_subscription_notification_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_subscription_notification_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_no_circular_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  current_user_id INTEGER := p_sponsor_user_id;
  max_depth INTEGER := 10; -- Safety limit
  depth INTEGER := 0;
BEGIN
  -- Check if sponsor would create a circular reference
  WHILE current_user_id IS NOT NULL AND depth < max_depth LOOP
    -- If we find the referred user in the sponsor's upline, it's circular
    IF current_user_id = p_referred_user_id THEN
      RETURN FALSE;
    END IF;
    
    -- Get next level up
    SELECT sponsor_user_id INTO current_user_id
    FROM public.affiliate_referrals
    WHERE referred_user_id = current_user_id 
    AND company_id = p_company_id
    AND status = 'active';
    
    depth := depth + 1;
  END LOOP;
  
  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."validate_no_circular_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."active_sessions" (
    "id" bigint NOT NULL,
    "session_id" character varying(100) NOT NULL,
    "affiliate_code" character varying(50),
    "start_time" timestamp with time zone DEFAULT "now"(),
    "last_activity" timestamp with time zone DEFAULT "now"(),
    "total_active_time" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "ip_address" "inet",
    "user_agent" "text",
    "referrer" "text",
    "screen_resolution" character varying(20),
    "timezone" character varying(50),
    "company_id" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."active_sessions" OWNER TO "postgres";


COMMENT ON TABLE "public"."active_sessions" IS 'Sessões ativas dos usuários';



CREATE SEQUENCE IF NOT EXISTS "public"."active_sessions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."active_sessions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."active_sessions_id_seq" OWNED BY "public"."active_sessions"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_addresses" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "cep" character varying(10),
    "street" character varying(255),
    "city" character varying(100),
    "state" character varying(2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "house_number" character varying(20),
    "neighborhood" character varying(100)
);


ALTER TABLE "public"."affiliate_addresses" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_addresses_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_addresses_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_addresses_id_seq" OWNED BY "public"."affiliate_addresses"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_bank_data" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "bank_name" character varying(100),
    "agency" character varying(10),
    "account" character varying(20),
    "account_type" character varying(20),
    "pix_key" character varying(255),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "affiliate_bank_data_account_type_check" CHECK ((("account_type")::"text" = ANY ((ARRAY['corrente'::character varying, 'poupanca'::character varying])::"text"[])))
);


ALTER TABLE "public"."affiliate_bank_data" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_bank_data_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_bank_data_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_bank_data_id_seq" OWNED BY "public"."affiliate_bank_data"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_commissions_earned" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "order_item_id" integer,
    "amount" numeric NOT NULL,
    "status" "public"."commission_status" NOT NULL,
    "earned_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "source_sale_id" integer,
    "commission_type" character varying(20) DEFAULT 'direct'::character varying,
    "level" integer DEFAULT 1,
    "source_affiliate_user_id" integer
);


ALTER TABLE "public"."affiliate_commissions_earned" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_commissions_earned_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_commissions_earned_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_commissions_earned_id_seq" OWNED BY "public"."affiliate_commissions_earned"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_conversions" (
    "id" integer NOT NULL,
    "affiliate_link_id" integer NOT NULL,
    "user_id" integer,
    "company_id" integer NOT NULL,
    "sale_id" integer,
    "commission_amount" numeric(10,2),
    "converted_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."affiliate_conversions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_conversions_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_conversions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_conversions_id_seq" OWNED BY "public"."affiliate_conversions"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_invitations" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "token" character varying(255) NOT NULL,
    "email" character varying(255),
    "created_by" integer NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '7 days'::interval) NOT NULL,
    "used_at" timestamp with time zone,
    "used_by" integer,
    "status" character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."affiliate_invitations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_invitations_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_invitations_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_invitations_id_seq" OWNED BY "public"."affiliate_invitations"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_link_clicks" (
    "id" integer NOT NULL,
    "affiliate_link_id" integer NOT NULL,
    "user_id" integer,
    "company_id" integer NOT NULL,
    "ip_address" "inet",
    "user_agent" "text",
    "referrer" "text",
    "clicked_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."affiliate_link_clicks" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_link_clicks_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_link_clicks_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_link_clicks_id_seq" OWNED BY "public"."affiliate_link_clicks"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_links" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "product_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "code" character varying NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."affiliate_links" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_links_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_links_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_links_id_seq" OWNED BY "public"."affiliate_links"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_payments" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "withdrawal_request_id" integer,
    "amount" numeric NOT NULL,
    "payment_date" timestamp without time zone NOT NULL,
    "method" character varying,
    "transaction_id" character varying,
    "status" "public"."payment_status" NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."affiliate_payments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_payments_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_payments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_payments_id_seq" OWNED BY "public"."affiliate_payments"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_profiles" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "full_name" character varying(255) NOT NULL,
    "email" character varying(255) NOT NULL,
    "phone" character varying(20),
    "cpf" character varying(14),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."affiliate_profiles" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_profiles_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_profiles_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_profiles_id_seq" OWNED BY "public"."affiliate_profiles"."id";



CREATE TABLE IF NOT EXISTS "public"."affiliate_referrals" (
    "id" integer NOT NULL,
    "sponsor_user_id" integer NOT NULL,
    "referred_user_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "status" character varying(20) DEFAULT 'active'::character varying,
    CONSTRAINT "no_self_referral" CHECK (("sponsor_user_id" <> "referred_user_id"))
);


ALTER TABLE "public"."affiliate_referrals" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."affiliate_referrals_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."affiliate_referrals_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."affiliate_referrals_id_seq" OWNED BY "public"."affiliate_referrals"."id";



CREATE TABLE IF NOT EXISTS "public"."companies" (
    "id" integer NOT NULL,
    "name" character varying NOT NULL,
    "subdomain" character varying NOT NULL,
    "subscription_id" integer,
    "white_label_settings" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."companies" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."companies_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."companies_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."companies_id_seq" OWNED BY "public"."companies"."id";



CREATE TABLE IF NOT EXISTS "public"."company_mlm_levels" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "level" integer NOT NULL,
    "commission_percentage" numeric(5,2) NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "company_mlm_levels_commission_percentage_check" CHECK ((("commission_percentage" >= (0)::numeric) AND ("commission_percentage" <= (100)::numeric))),
    CONSTRAINT "company_mlm_levels_level_check" CHECK ((("level" >= 1) AND ("level" <= 5)))
);


ALTER TABLE "public"."company_mlm_levels" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."company_mlm_levels_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."company_mlm_levels_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."company_mlm_levels_id_seq" OWNED BY "public"."company_mlm_levels"."id";



CREATE TABLE IF NOT EXISTS "public"."company_settings" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "settings_data" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "checkout_type" character varying(20) DEFAULT 'payment'::character varying,
    "payment_link" "text",
    "whatsapp_number" character varying(20),
    "whatsapp_message" "text" DEFAULT 'Olá! Gostaria de finalizar a compra do produto: {product_name} no valor de R$ {price}'::"text",
    "whatsapp_message_mode" character varying(20) DEFAULT 'auto'::character varying,
    "whatsapp_auto_template" "text",
    CONSTRAINT "company_settings_checkout_type_check" CHECK ((("checkout_type")::"text" = ANY ((ARRAY['payment'::character varying, 'whatsapp'::character varying, 'whatsform'::character varying])::"text"[]))),
    CONSTRAINT "company_settings_whatsapp_message_mode_check" CHECK ((("whatsapp_message_mode")::"text" = ANY ((ARRAY['auto'::character varying, 'manual'::character varying])::"text"[])))
);


ALTER TABLE "public"."company_settings" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."company_settings_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."company_settings_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."company_settings_id_seq" OWNED BY "public"."company_settings"."id";



CREATE TABLE IF NOT EXISTS "public"."company_subscriptions" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "subscription_id" integer NOT NULL,
    "signed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "status" "public"."subscription_status" DEFAULT 'active'::"public"."subscription_status" NOT NULL,
    "notify_3_days_sent" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."company_subscriptions" OWNER TO "postgres";


ALTER TABLE "public"."company_subscriptions" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."company_subscriptions_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."coupons" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "code" character varying NOT NULL,
    "value" numeric NOT NULL,
    "expires_at" "date",
    "product_id" integer,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "max_uses" integer,
    "used_count" integer DEFAULT 0,
    "active" boolean DEFAULT true,
    "discount_type" "public"."discount_type_new",
    "affiliate_user_id" integer
);


ALTER TABLE "public"."coupons" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."coupons_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."coupons_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."coupons_id_seq" OWNED BY "public"."coupons"."id";



CREATE TABLE IF NOT EXISTS "public"."engagement_events" (
    "id" bigint NOT NULL,
    "session_id" character varying(100) NOT NULL,
    "affiliate_code" character varying(50),
    "event_type" character varying(50) NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"(),
    "duration" integer,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "ip_address" "inet",
    "user_agent" "text",
    "company_id" integer,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."engagement_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."engagement_events" IS 'Eventos de engajamento da jornada do cliente';



CREATE SEQUENCE IF NOT EXISTS "public"."engagement_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."engagement_events_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."engagement_events_id_seq" OWNED BY "public"."engagement_events"."id";



CREATE OR REPLACE VIEW "public"."hot_leads" AS
 WITH "session_scores" AS (
         SELECT "s"."session_id",
            "s"."affiliate_code",
            "s"."company_id",
            "s"."total_active_time",
            "s"."last_activity",
            "count"("e"."id") AS "interaction_count",
            "count"(
                CASE
                    WHEN (("e"."event_type")::"text" = ANY ((ARRAY['form_start'::character varying, 'checkout_start'::character varying, 'intention_cta'::character varying])::"text"[])) THEN 1
                    ELSE NULL::integer
                END) AS "high_intent_events",
            "public"."calculate_engagement_score"("s"."session_id") AS "engagement_score"
           FROM ("public"."active_sessions" "s"
             LEFT JOIN "public"."engagement_events" "e" ON ((("s"."session_id")::"text" = ("e"."session_id")::"text")))
          WHERE (("s"."is_active" = true) AND ("s"."last_activity" >= ("now"() - '00:30:00'::interval)))
          GROUP BY "s"."session_id", "s"."affiliate_code", "s"."company_id", "s"."total_active_time", "s"."last_activity"
        )
 SELECT "session_id",
    "affiliate_code",
    "company_id",
    "total_active_time",
    "interaction_count",
    "high_intent_events",
    "engagement_score",
        CASE
            WHEN ("engagement_score" >= 80) THEN 'hot'::"text"
            WHEN ("engagement_score" >= 60) THEN 'warm'::"text"
            WHEN ("engagement_score" >= 40) THEN 'mild'::"text"
            ELSE 'cold'::"text"
        END AS "lead_temperature"
   FROM "session_scores"
  WHERE (("total_active_time" > 300) OR ("interaction_count" > 5) OR ("high_intent_events" > 0))
  ORDER BY "engagement_score" DESC;


ALTER VIEW "public"."hot_leads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."leads" (
    "id" integer NOT NULL,
    "name" character varying(255) NOT NULL,
    "email" character varying(255) NOT NULL,
    "phone" character varying(50),
    "product_id" integer,
    "product_name" character varying(255) NOT NULL,
    "affiliate_code" character varying(100),
    "affiliate_user_id" integer,
    "company_id" integer NOT NULL,
    "ip_address" "inet",
    "user_agent" "text",
    "referrer" "text",
    "status" character varying(50) DEFAULT 'new'::character varying,
    "converted" boolean DEFAULT false,
    "conversion_date" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."leads" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."leads_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."leads_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."leads_id_seq" OWNED BY "public"."leads"."id";



CREATE TABLE IF NOT EXISTS "public"."members" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "name" character varying NOT NULL,
    "email" character varying NOT NULL,
    "membership_plan_id" integer,
    "status" character varying DEFAULT 'active'::character varying,
    "join_date" timestamp without time zone DEFAULT "now"(),
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "members_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['active'::character varying, 'inactive'::character varying])::"text"[])))
);


ALTER TABLE "public"."members" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."members_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."members_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."members_id_seq" OWNED BY "public"."members"."id";



CREATE TABLE IF NOT EXISTS "public"."membership_plans" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "name" character varying NOT NULL,
    "price" numeric(10,2) NOT NULL,
    "active" boolean DEFAULT true,
    "features" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."membership_plans" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."membership_plans_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."membership_plans_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."membership_plans_id_seq" OWNED BY "public"."membership_plans"."id";



CREATE TABLE IF NOT EXISTS "public"."migrations_log" (
    "id" integer NOT NULL,
    "migration_name" character varying(255) NOT NULL,
    "executed_at" timestamp with time zone DEFAULT "now"(),
    "description" "text"
);


ALTER TABLE "public"."migrations_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."migrations_log_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."migrations_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."migrations_log_id_seq" OWNED BY "public"."migrations_log"."id";



CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "title" character varying(255) NOT NULL,
    "message" "text" NOT NULL,
    "type" character varying(50) DEFAULT 'info'::character varying NOT NULL,
    "read" boolean DEFAULT false NOT NULL,
    "data" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."notifications" REPLICA IDENTITY FULL;


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."notifications_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."notifications_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."notifications_id_seq" OWNED BY "public"."notifications"."id";



CREATE TABLE IF NOT EXISTS "public"."order_items" (
    "id" integer NOT NULL,
    "order_id" integer NOT NULL,
    "product_id" integer NOT NULL,
    "quantity" integer NOT NULL,
    "price_per_item" numeric NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."order_items" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."order_items_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."order_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."order_items_id_seq" OWNED BY "public"."order_items"."id";



CREATE TABLE IF NOT EXISTS "public"."orders" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "customer_user_id" integer,
    "affiliate_user_id" integer,
    "total_amount" numeric NOT NULL,
    "status" "public"."order_status" NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."orders" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."orders_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."orders_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."orders_id_seq" OWNED BY "public"."orders"."id";



CREATE TABLE IF NOT EXISTS "public"."payment_receipts" (
    "id" integer NOT NULL,
    "payment_id" integer NOT NULL,
    "file_name" character varying(255) NOT NULL,
    "file_size" integer NOT NULL,
    "file_type" character varying(50) NOT NULL,
    "file_url" "text" NOT NULL,
    "uploaded_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "uploaded_by" integer NOT NULL,
    "company_id" integer NOT NULL
);


ALTER TABLE "public"."payment_receipts" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."payment_receipts_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."payment_receipts_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."payment_receipts_id_seq" OWNED BY "public"."payment_receipts"."id";



CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" integer NOT NULL,
    "affiliate_user_id" integer NOT NULL,
    "affiliate_name" character varying NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "status" character varying(20) NOT NULL,
    "payment_method" character varying(50) NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp without time zone,
    "company_id" integer NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "description" "text",
    "notes" "text",
    "bank_info" "jsonb",
    "pix_key" character varying(255),
    CONSTRAINT "payments_status_check" CHECK ((("status")::"text" = ANY ((ARRAY['pending'::character varying, 'processed'::character varying, 'failed'::character varying])::"text"[])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."payments_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."payments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."payments_id_seq" OWNED BY "public"."payments"."id";



CREATE TABLE IF NOT EXISTS "public"."platform_settings" (
    "id" integer DEFAULT 1 NOT NULL,
    "platform_name" character varying(255) DEFAULT 'AffiliateHub'::character varying NOT NULL,
    "platform_url" character varying(255) DEFAULT 'https://affiliatehub.com'::character varying NOT NULL,
    "support_email" character varying(255) DEFAULT 'support@affiliatehub.com'::character varying NOT NULL,
    "payment_gateway" character varying(50) DEFAULT 'Stripe'::character varying NOT NULL,
    "default_currency" character varying(10) DEFAULT 'BRL'::character varying NOT NULL,
    "platform_fee_percentage" numeric(5,2) DEFAULT 5.00 NOT NULL,
    "basic_plan_user_limit" integer DEFAULT 10 NOT NULL,
    "professional_plan_user_limit" integer DEFAULT 50 NOT NULL,
    "enterprise_plan_user_limit" integer DEFAULT 100 NOT NULL,
    "require_2fa_for_admins" boolean DEFAULT true NOT NULL,
    "enable_audit_log" boolean DEFAULT true NOT NULL,
    "enable_auto_backup" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "platform_logo_url" "text",
    CONSTRAINT "check_single_settings_row" CHECK (("id" = 1))
);


ALTER TABLE "public"."platform_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."platform_subscriptions_payments" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "subscription_id" integer NOT NULL,
    "amount" numeric NOT NULL,
    "payment_date" timestamp without time zone NOT NULL,
    "status" "public"."payment_status" NOT NULL,
    "transaction_id" character varying,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."platform_subscriptions_payments" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."platform_subscriptions_payments_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."platform_subscriptions_payments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."platform_subscriptions_payments_id_seq" OWNED BY "public"."platform_subscriptions_payments"."id";



CREATE TABLE IF NOT EXISTS "public"."product_commissions" (
    "id" integer NOT NULL,
    "product_id" integer NOT NULL,
    "type" "public"."commission_type" NOT NULL,
    "value" numeric NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."product_commissions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."product_commissions_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."product_commissions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."product_commissions_id_seq" OWNED BY "public"."product_commissions"."id";



CREATE TABLE IF NOT EXISTS "public"."product_discount_settings" (
    "id" integer NOT NULL,
    "product_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "discount_type" "public"."discount_type_new" DEFAULT 'percentage'::"public"."discount_type_new" NOT NULL,
    "discount_value" numeric NOT NULL,
    "max_discount_amount" numeric,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "product_discount_settings_discount_value_check" CHECK (("discount_value" > (0)::numeric))
);


ALTER TABLE "public"."product_discount_settings" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."product_discount_settings_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."product_discount_settings_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."product_discount_settings_id_seq" OWNED BY "public"."product_discount_settings"."id";



CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "name" character varying NOT NULL,
    "description" "text",
    "price" numeric NOT NULL,
    "type" "public"."product_type" NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "stock_quantity" integer DEFAULT 0 NOT NULL,
    "unlimited_stock" boolean DEFAULT false NOT NULL,
    "checkout_type" character varying(20) DEFAULT 'payment'::character varying,
    "whatsform_discount_amount" numeric(10,2) DEFAULT 300.00,
    "checkout_title" "text" DEFAULT 'Checkout'::"text",
    "checkout_subtitle" "text" DEFAULT 'Finalize sua compra de forma rápida e segura'::"text",
    "image_url" "text",
    CONSTRAINT "products_checkout_type_check" CHECK ((("checkout_type")::"text" = ANY ((ARRAY['payment'::character varying, 'whatsapp'::character varying, 'whatsform'::character varying])::"text"[])))
);


ALTER TABLE "public"."products" OWNER TO "postgres";


COMMENT ON COLUMN "public"."products"."checkout_type" IS 'Tipo de checkout para este produto: payment (gateway), whatsapp (redirecionamento) ou whatsform (formulário lead)';



COMMENT ON COLUMN "public"."products"."whatsform_discount_amount" IS 'Valor do desconto que aparece na mensagem do WhatsForm (ex: R$300)';



CREATE SEQUENCE IF NOT EXISTS "public"."products_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."products_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."products_id_seq" OWNED BY "public"."products"."id";



CREATE OR REPLACE VIEW "public"."real_time_engagement_metrics" AS
 SELECT "company_id",
    "affiliate_code",
    "count"(DISTINCT "session_id") AS "active_sessions",
    "avg"("total_active_time") AS "avg_active_time",
    "sum"(
        CASE
            WHEN ("last_activity" >= ("now"() - '00:30:00'::interval)) THEN 1
            ELSE 0
        END) AS "recent_sessions"
   FROM "public"."active_sessions"
  WHERE ("is_active" = true)
  GROUP BY "company_id", "affiliate_code";


ALTER VIEW "public"."real_time_engagement_metrics" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."recent_engagement_events" AS
 SELECT "session_id",
    "affiliate_code",
    "event_type",
    "timestamp",
    "metadata",
    "company_id",
        CASE
            WHEN (("event_type")::"text" = ANY ((ARRAY['intention_cta'::character varying, 'negotiation_start'::character varying, 'checkout_complete'::character varying])::"text"[])) THEN 'critical'::"text"
            WHEN (("event_type")::"text" = ANY ((ARRAY['form_complete'::character varying, 'checkout_start'::character varying, 'form_start'::character varying])::"text"[])) THEN 'important'::"text"
            ELSE 'normal'::"text"
        END AS "event_priority"
   FROM "public"."engagement_events"
  WHERE ("timestamp" >= ("now"() - '00:30:00'::interval))
  ORDER BY "timestamp" DESC;


ALTER VIEW "public"."recent_engagement_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."roles" (
    "id" integer NOT NULL,
    "name" character varying NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "roles_name_check" CHECK ((("name")::"text" = ANY ((ARRAY['super_admin'::character varying, 'admin_empresa'::character varying, 'afiliado'::character varying, 'user'::character varying])::"text"[])))
);


ALTER TABLE "public"."roles" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."roles_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."roles_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."roles_id_seq" OWNED BY "public"."roles"."id";



CREATE TABLE IF NOT EXISTS "public"."sales" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "affiliate_user_id" integer,
    "customer_name" character varying(255) NOT NULL,
    "customer_email" character varying(255) NOT NULL,
    "product_name" character varying(255) NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "commission_amount" numeric(10,2) DEFAULT 0,
    "coupon_code" character varying(50),
    "referral_source" character varying(255),
    "status" character varying(50) DEFAULT 'pending'::character varying NOT NULL,
    "payment_method" character varying(100),
    "transaction_id" character varying(255),
    "sale_date" timestamp without time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    "created_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sales_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sales_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sales_id_seq" OWNED BY "public"."sales"."id";



CREATE TABLE IF NOT EXISTS "public"."stage_engagement_metrics" (
    "id" bigint NOT NULL,
    "company_id" integer,
    "affiliate_code" character varying(50),
    "stage_id" character varying(50) NOT NULL,
    "date" "date" DEFAULT CURRENT_DATE,
    "total_time_seconds" integer DEFAULT 0,
    "active_time_seconds" integer DEFAULT 0,
    "total_interactions" integer DEFAULT 0,
    "total_sessions" integer DEFAULT 0,
    "completed_sessions" integer DEFAULT 0,
    "average_engagement_score" numeric(5,2) DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."stage_engagement_metrics" OWNER TO "postgres";


COMMENT ON TABLE "public"."stage_engagement_metrics" IS 'Métricas agregadas por estágio';



CREATE SEQUENCE IF NOT EXISTS "public"."stage_engagement_metrics_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."stage_engagement_metrics_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."stage_engagement_metrics_id_seq" OWNED BY "public"."stage_engagement_metrics"."id";



CREATE TABLE IF NOT EXISTS "public"."subscription_notification_settings" (
    "id" integer DEFAULT 1 NOT NULL,
    "warning_24h_enabled" boolean DEFAULT true,
    "warning_24h_title" "text" DEFAULT 'Assinatura Vencendo em Breve'::"text",
    "warning_24h_message" "text" DEFAULT 'Sua assinatura vence em menos de 24 horas. Renove agora para evitar interrupções no serviço.'::"text",
    "expired_title" "text" DEFAULT 'Assinatura Expirada'::"text",
    "expired_message" "text" DEFAULT 'Sua assinatura expirou. Renove agora para continuar usando todos os recursos.'::"text",
    "blocked_title" "text" DEFAULT 'Acesso Bloqueado'::"text",
    "blocked_message" "text" DEFAULT 'Sua assinatura está vencida há mais de 3 dias. O acesso foi bloqueado até a renovação.'::"text",
    "payment_url" "text" DEFAULT 'https://pay.example.com'::"text",
    "whatsapp_number" "text" DEFAULT '5511999999999'::"text",
    "whatsapp_message" "text" DEFAULT 'Olá! Preciso renovar minha assinatura.'::"text",
    "block_after_days" integer DEFAULT 3,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "warning_show_frequency_hours" integer DEFAULT 24,
    "warning_max_shows_per_day" integer DEFAULT 2,
    "expired_show_frequency_hours" integer DEFAULT 12,
    "expired_max_shows_per_day" integer DEFAULT 3,
    "blocked_show_frequency_hours" integer DEFAULT 6,
    "blocked_max_shows_per_day" integer DEFAULT 5
);


ALTER TABLE "public"."subscription_notification_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_notifications_history" (
    "id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "notification_type" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"(),
    "company_subscription_id" integer,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."subscription_notifications_history" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."subscription_notifications_history_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."subscription_notifications_history_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."subscription_notifications_history_id_seq" OWNED BY "public"."subscription_notifications_history"."id";



CREATE TABLE IF NOT EXISTS "public"."subscriptions" (
    "id" integer NOT NULL,
    "name" character varying NOT NULL,
    "price" numeric NOT NULL,
    "features" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "user_limit" integer DEFAULT 10,
    "whitelabel" boolean DEFAULT false,
    "feature_analytics" boolean DEFAULT true,
    "feature_reports" boolean DEFAULT true,
    "feature_integrations" boolean DEFAULT false,
    "feature_priority_support" boolean DEFAULT false,
    "feature_custom_domain" boolean DEFAULT false,
    "duration_value" integer DEFAULT 30,
    "duration_unit" "public"."subscription_duration_unit" DEFAULT 'days'::"public"."subscription_duration_unit"
);


ALTER TABLE "public"."subscriptions" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."subscriptions_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."subscriptions_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."subscriptions_id_seq" OWNED BY "public"."subscriptions"."id";



CREATE TABLE IF NOT EXISTS "public"."thank_you_page_visits" (
    "id" bigint NOT NULL,
    "session_id" character varying(100) NOT NULL,
    "affiliate_code" character varying(50),
    "product_id" integer,
    "company_id" integer,
    "customer_name" character varying(255),
    "customer_email" character varying(255),
    "order_value" numeric(10,2),
    "lead_type" character varying(50),
    "whatsapp_url" "text",
    "visited_at" timestamp with time zone DEFAULT "now"(),
    "auto_redirect_completed" boolean DEFAULT false,
    "manual_redirect_completed" boolean DEFAULT false,
    "redirect_completed_at" timestamp with time zone,
    "ip_address" "inet",
    "user_agent" "text",
    "referrer" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."thank_you_page_visits" OWNER TO "postgres";


COMMENT ON TABLE "public"."thank_you_page_visits" IS 'Tracking da página de agradecimento';



CREATE OR REPLACE VIEW "public"."thank_you_page_stats" AS
 SELECT "company_id",
    "affiliate_code",
    "lead_type",
    "date"("visited_at") AS "visit_date",
    "count"(*) AS "total_visits",
    "count"(
        CASE
            WHEN "auto_redirect_completed" THEN 1
            ELSE NULL::integer
        END) AS "auto_redirects",
    "count"(
        CASE
            WHEN "manual_redirect_completed" THEN 1
            ELSE NULL::integer
        END) AS "manual_redirects",
    "count"(
        CASE
            WHEN ("auto_redirect_completed" OR "manual_redirect_completed") THEN 1
            ELSE NULL::integer
        END) AS "total_redirects",
    "round"(((("count"(
        CASE
            WHEN ("auto_redirect_completed" OR "manual_redirect_completed") THEN 1
            ELSE NULL::integer
        END))::numeric * 100.0) / ("count"(*))::numeric), 2) AS "redirect_rate",
    "avg"("order_value") AS "avg_order_value",
    "sum"("order_value") AS "total_order_value"
   FROM "public"."thank_you_page_visits"
  GROUP BY "company_id", "affiliate_code", "lead_type", ("date"("visited_at"))
  ORDER BY ("date"("visited_at")) DESC;


ALTER VIEW "public"."thank_you_page_stats" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."thank_you_page_visits_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."thank_you_page_visits_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."thank_you_page_visits_id_seq" OWNED BY "public"."thank_you_page_visits"."id";



CREATE TABLE IF NOT EXISTS "public"."user_audit_logs" (
    "id" integer NOT NULL,
    "user_id" integer,
    "action" character varying(50) NOT NULL,
    "changed_by" integer,
    "old_values" "jsonb",
    "new_values" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_audit_logs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."user_audit_logs_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."user_audit_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."user_audit_logs_id_seq" OWNED BY "public"."user_audit_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."user_bank_details" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "pix_key" character varying,
    "bank_name" character varying,
    "account_details" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_bank_details" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."user_bank_details_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."user_bank_details_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."user_bank_details_id_seq" OWNED BY "public"."user_bank_details"."id";



CREATE TABLE IF NOT EXISTS "public"."user_cache" (
    "auth_user_id" "uuid" NOT NULL,
    "user_id" integer NOT NULL,
    "role_id" integer NOT NULL,
    "company_id" integer,
    "email" "text" NOT NULL,
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_cache" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_settings" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "settings_data" "jsonb",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_settings" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."user_settings_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."user_settings_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."user_settings_id_seq" OWNED BY "public"."user_settings"."id";



CREATE TABLE IF NOT EXISTS "public"."users" (
    "id" integer NOT NULL,
    "role_id" integer NOT NULL,
    "company_id" integer,
    "name" character varying NOT NULL,
    "email" character varying NOT NULL,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    "status" "public"."user_status" DEFAULT 'active'::"public"."user_status"
);


ALTER TABLE "public"."users" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."users_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."users_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."users_id_seq" OWNED BY "public"."users"."id";



CREATE TABLE IF NOT EXISTS "public"."withdrawal_requests" (
    "id" integer NOT NULL,
    "user_id" integer NOT NULL,
    "company_id" integer NOT NULL,
    "amount" numeric NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "requested_at" timestamp without time zone DEFAULT "now"() NOT NULL,
    "processed_at" timestamp without time zone,
    "created_at" timestamp without time zone DEFAULT "now"(),
    "updated_at" timestamp without time zone DEFAULT "now"(),
    CONSTRAINT "withdrawal_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'completed'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."withdrawal_requests" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."withdrawal_requests_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."withdrawal_requests_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."withdrawal_requests_id_seq" OWNED BY "public"."withdrawal_requests"."id";



ALTER TABLE ONLY "public"."active_sessions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."active_sessions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_addresses" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_addresses_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_bank_data" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_bank_data_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_commissions_earned" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_commissions_earned_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_conversions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_conversions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_invitations" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_invitations_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_link_clicks" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_link_clicks_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_links" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_links_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_payments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_payments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_profiles" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_profiles_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."affiliate_referrals" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."affiliate_referrals_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."companies" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."companies_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."company_mlm_levels" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."company_mlm_levels_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."company_settings" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."company_settings_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."coupons" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."coupons_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."engagement_events" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."engagement_events_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."leads" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."leads_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."members" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."members_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."membership_plans" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."membership_plans_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."migrations_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."migrations_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."notifications" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."notifications_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."order_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."order_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."orders" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."orders_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."payment_receipts" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."payment_receipts_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."payments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."payments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."platform_subscriptions_payments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."platform_subscriptions_payments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."product_commissions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."product_commissions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."product_discount_settings" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."product_discount_settings_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."products" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."products_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."roles" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."roles_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sales" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sales_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."stage_engagement_metrics" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."stage_engagement_metrics_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."subscription_notifications_history" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."subscription_notifications_history_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."subscriptions" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."subscriptions_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."thank_you_page_visits" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."thank_you_page_visits_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."user_audit_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."user_audit_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."user_bank_details" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."user_bank_details_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."user_settings" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."user_settings_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."users" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."users_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."withdrawal_requests" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."withdrawal_requests_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."active_sessions"
    ADD CONSTRAINT "active_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."active_sessions"
    ADD CONSTRAINT "active_sessions_session_id_key" UNIQUE ("session_id");



ALTER TABLE ONLY "public"."affiliate_addresses"
    ADD CONSTRAINT "affiliate_addresses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_addresses"
    ADD CONSTRAINT "affiliate_addresses_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."affiliate_bank_data"
    ADD CONSTRAINT "affiliate_bank_data_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_bank_data"
    ADD CONSTRAINT "affiliate_bank_data_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."affiliate_commissions_earned"
    ADD CONSTRAINT "affiliate_commissions_earned_order_item_id_key" UNIQUE ("order_item_id");



ALTER TABLE ONLY "public"."affiliate_commissions_earned"
    ADD CONSTRAINT "affiliate_commissions_earned_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_conversions"
    ADD CONSTRAINT "affiliate_conversions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_invitations"
    ADD CONSTRAINT "affiliate_invitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_invitations"
    ADD CONSTRAINT "affiliate_invitations_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."affiliate_link_clicks"
    ADD CONSTRAINT "affiliate_link_clicks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_links"
    ADD CONSTRAINT "affiliate_links_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."affiliate_links"
    ADD CONSTRAINT "affiliate_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_payments"
    ADD CONSTRAINT "affiliate_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_profiles"
    ADD CONSTRAINT "affiliate_profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_profiles"
    ADD CONSTRAINT "affiliate_profiles_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."affiliate_referrals"
    ADD CONSTRAINT "affiliate_referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."affiliate_referrals"
    ADD CONSTRAINT "affiliate_referrals_referred_user_id_company_id_key" UNIQUE ("referred_user_id", "company_id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_subdomain_key" UNIQUE ("subdomain");



ALTER TABLE ONLY "public"."company_mlm_levels"
    ADD CONSTRAINT "company_mlm_levels_company_id_level_key" UNIQUE ("company_id", "level");



ALTER TABLE ONLY "public"."company_mlm_levels"
    ADD CONSTRAINT "company_mlm_levels_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_settings"
    ADD CONSTRAINT "company_settings_company_id_key" UNIQUE ("company_id");



ALTER TABLE ONLY "public"."company_settings"
    ADD CONSTRAINT "company_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_subscriptions"
    ADD CONSTRAINT "company_subscriptions_company_id_key" UNIQUE ("company_id");



ALTER TABLE ONLY "public"."company_subscriptions"
    ADD CONSTRAINT "company_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."engagement_events"
    ADD CONSTRAINT "engagement_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."membership_plans"
    ADD CONSTRAINT "membership_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."migrations_log"
    ADD CONSTRAINT "migrations_log_migration_name_key" UNIQUE ("migration_name");



ALTER TABLE ONLY "public"."migrations_log"
    ADD CONSTRAINT "migrations_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_receipts"
    ADD CONSTRAINT "payment_receipts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."platform_settings"
    ADD CONSTRAINT "platform_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."platform_subscriptions_payments"
    ADD CONSTRAINT "platform_subscriptions_payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_commissions"
    ADD CONSTRAINT "product_commissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_discount_settings"
    ADD CONSTRAINT "product_discount_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_discount_settings"
    ADD CONSTRAINT "product_discount_settings_product_id_company_id_key" UNIQUE ("product_id", "company_id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stage_engagement_metrics"
    ADD CONSTRAINT "stage_engagement_metrics_company_id_affiliate_code_stage_id_key" UNIQUE ("company_id", "affiliate_code", "stage_id", "date");



ALTER TABLE ONLY "public"."stage_engagement_metrics"
    ADD CONSTRAINT "stage_engagement_metrics_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscription_notification_settings"
    ADD CONSTRAINT "subscription_notification_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscription_notifications_history"
    ADD CONSTRAINT "subscription_notifications_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."thank_you_page_visits"
    ADD CONSTRAINT "thank_you_page_visits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "unique_company_code" UNIQUE ("company_id", "code");



ALTER TABLE ONLY "public"."stage_engagement_metrics"
    ADD CONSTRAINT "unique_stage_metrics" UNIQUE ("company_id", "affiliate_code", "stage_id", "date");



ALTER TABLE ONLY "public"."user_audit_logs"
    ADD CONSTRAINT "user_audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_bank_details"
    ADD CONSTRAINT "user_bank_details_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_bank_details"
    ADD CONSTRAINT "user_bank_details_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."user_cache"
    ADD CONSTRAINT "user_cache_pkey" PRIMARY KEY ("auth_user_id");



ALTER TABLE ONLY "public"."user_settings"
    ADD CONSTRAINT "user_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_key" UNIQUE ("user_id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."withdrawal_requests"
    ADD CONSTRAINT "withdrawal_requests_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_active_sessions_affiliate_code" ON "public"."active_sessions" USING "btree" ("affiliate_code");



CREATE INDEX "idx_active_sessions_company_id" ON "public"."active_sessions" USING "btree" ("company_id");



CREATE INDEX "idx_active_sessions_hot_leads" ON "public"."active_sessions" USING "btree" ("last_activity", "is_active", "total_active_time") WHERE ("is_active" = true);



CREATE INDEX "idx_active_sessions_is_active" ON "public"."active_sessions" USING "btree" ("is_active");



CREATE INDEX "idx_active_sessions_last_activity" ON "public"."active_sessions" USING "btree" ("last_activity");



CREATE INDEX "idx_active_sessions_session_id" ON "public"."active_sessions" USING "btree" ("session_id");



CREATE INDEX "idx_affiliate_commissions_earned_company_id" ON "public"."affiliate_commissions_earned" USING "btree" ("company_id");



CREATE INDEX "idx_affiliate_commissions_earned_earned_at" ON "public"."affiliate_commissions_earned" USING "btree" ("earned_at");



CREATE UNIQUE INDEX "idx_affiliate_commissions_earned_order_item_id" ON "public"."affiliate_commissions_earned" USING "btree" ("order_item_id");



CREATE INDEX "idx_affiliate_commissions_earned_status" ON "public"."affiliate_commissions_earned" USING "btree" ("status");



CREATE INDEX "idx_affiliate_commissions_earned_user_id" ON "public"."affiliate_commissions_earned" USING "btree" ("user_id");



CREATE INDEX "idx_affiliate_commissions_status" ON "public"."affiliate_commissions_earned" USING "btree" ("status");



CREATE INDEX "idx_affiliate_commissions_user_company" ON "public"."affiliate_commissions_earned" USING "btree" ("user_id", "company_id");



CREATE INDEX "idx_affiliate_commissions_user_company_date" ON "public"."affiliate_commissions_earned" USING "btree" ("user_id", "company_id", "earned_at");



CREATE INDEX "idx_affiliate_invitations_company_id" ON "public"."affiliate_invitations" USING "btree" ("company_id");



CREATE INDEX "idx_affiliate_invitations_status" ON "public"."affiliate_invitations" USING "btree" ("status");



CREATE INDEX "idx_affiliate_invitations_token" ON "public"."affiliate_invitations" USING "btree" ("token");



CREATE UNIQUE INDEX "idx_affiliate_links_code" ON "public"."affiliate_links" USING "btree" ("code");



CREATE INDEX "idx_affiliate_links_company_id" ON "public"."affiliate_links" USING "btree" ("company_id");



CREATE INDEX "idx_affiliate_links_product_id" ON "public"."affiliate_links" USING "btree" ("product_id");



CREATE INDEX "idx_affiliate_links_user_id" ON "public"."affiliate_links" USING "btree" ("user_id");



CREATE INDEX "idx_affiliate_payments_company_id" ON "public"."affiliate_payments" USING "btree" ("company_id");



CREATE INDEX "idx_affiliate_payments_payment_date" ON "public"."affiliate_payments" USING "btree" ("payment_date");



CREATE INDEX "idx_affiliate_payments_user_id" ON "public"."affiliate_payments" USING "btree" ("user_id");



CREATE INDEX "idx_affiliate_payments_withdrawal_request_id" ON "public"."affiliate_payments" USING "btree" ("withdrawal_request_id");



CREATE INDEX "idx_affiliate_referrals_company" ON "public"."affiliate_referrals" USING "btree" ("company_id");



CREATE INDEX "idx_affiliate_referrals_referred" ON "public"."affiliate_referrals" USING "btree" ("referred_user_id");



CREATE INDEX "idx_affiliate_referrals_sponsor" ON "public"."affiliate_referrals" USING "btree" ("sponsor_user_id");



CREATE INDEX "idx_commissions_source_sale" ON "public"."affiliate_commissions_earned" USING "btree" ("source_sale_id");



CREATE INDEX "idx_commissions_type" ON "public"."affiliate_commissions_earned" USING "btree" ("commission_type");



CREATE UNIQUE INDEX "idx_companies_subdomain" ON "public"."companies" USING "btree" ("subdomain");



CREATE INDEX "idx_company_mlm_levels_company" ON "public"."company_mlm_levels" USING "btree" ("company_id");



CREATE INDEX "idx_company_settings_checkout_type" ON "public"."company_settings" USING "btree" ("checkout_type");



CREATE UNIQUE INDEX "idx_company_settings_company_id" ON "public"."company_settings" USING "btree" ("company_id");



CREATE INDEX "idx_company_subscriptions_expires_notify" ON "public"."company_subscriptions" USING "btree" ("expires_at", "notify_3_days_sent") WHERE ("status" = 'active'::"public"."subscription_status");



CREATE INDEX "idx_company_subscriptions_status_expires" ON "public"."company_subscriptions" USING "btree" ("status", "expires_at");



CREATE INDEX "idx_coupons_affiliate_product" ON "public"."coupons" USING "btree" ("affiliate_user_id", "product_id", "company_id") WHERE ("active" = true);



CREATE INDEX "idx_coupons_affiliate_user_id" ON "public"."coupons" USING "btree" ("affiliate_user_id");



CREATE INDEX "idx_coupons_code_company" ON "public"."coupons" USING "btree" ("code", "company_id") WHERE ("active" = true);



CREATE INDEX "idx_coupons_product_id" ON "public"."coupons" USING "btree" ("product_id");



CREATE INDEX "idx_engagement_events_affiliate_code" ON "public"."engagement_events" USING "btree" ("affiliate_code");



CREATE INDEX "idx_engagement_events_company_id" ON "public"."engagement_events" USING "btree" ("company_id");



CREATE INDEX "idx_engagement_events_critical_events" ON "public"."engagement_events" USING "btree" ("event_type") WHERE (("event_type")::"text" = ANY ((ARRAY['intention_cta'::character varying, 'negotiation_start'::character varying, 'checkout_complete'::character varying, 'form_complete'::character varying])::"text"[]));



CREATE INDEX "idx_engagement_events_event_type" ON "public"."engagement_events" USING "btree" ("event_type");



CREATE INDEX "idx_engagement_events_session_id" ON "public"."engagement_events" USING "btree" ("session_id");



CREATE INDEX "idx_engagement_events_timestamp" ON "public"."engagement_events" USING "btree" ("timestamp");



CREATE INDEX "idx_leads_affiliate_code" ON "public"."leads" USING "btree" ("affiliate_code");



CREATE INDEX "idx_leads_affiliate_user_id" ON "public"."leads" USING "btree" ("affiliate_user_id");



CREATE INDEX "idx_leads_company_id" ON "public"."leads" USING "btree" ("company_id");



CREATE INDEX "idx_leads_created_at" ON "public"."leads" USING "btree" ("created_at");



CREATE INDEX "idx_notifications_created_at" ON "public"."notifications" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_notifications_read" ON "public"."notifications" USING "btree" ("read");



CREATE INDEX "idx_notifications_user_company" ON "public"."notifications" USING "btree" ("user_id", "company_id");



CREATE INDEX "idx_order_items_order_id" ON "public"."order_items" USING "btree" ("order_id");



CREATE INDEX "idx_order_items_product_id" ON "public"."order_items" USING "btree" ("product_id");



CREATE INDEX "idx_orders_affiliate_user_id" ON "public"."orders" USING "btree" ("affiliate_user_id");



CREATE INDEX "idx_orders_company_id" ON "public"."orders" USING "btree" ("company_id");



CREATE INDEX "idx_orders_created_at" ON "public"."orders" USING "btree" ("created_at");



CREATE INDEX "idx_orders_customer_user_id" ON "public"."orders" USING "btree" ("customer_user_id");



CREATE INDEX "idx_platform_subscriptions_payments_company_id" ON "public"."platform_subscriptions_payments" USING "btree" ("company_id");



CREATE INDEX "idx_platform_subscriptions_payments_payment_date" ON "public"."platform_subscriptions_payments" USING "btree" ("payment_date");



CREATE INDEX "idx_platform_subscriptions_payments_subscription_id" ON "public"."platform_subscriptions_payments" USING "btree" ("subscription_id");



CREATE INDEX "idx_product_commissions_product_id" ON "public"."product_commissions" USING "btree" ("product_id");



CREATE INDEX "idx_product_discount_settings_product_company" ON "public"."product_discount_settings" USING "btree" ("product_id", "company_id");



CREATE INDEX "idx_products_company_id" ON "public"."products" USING "btree" ("company_id");



CREATE INDEX "idx_products_stock" ON "public"."products" USING "btree" ("stock_quantity") WHERE ("unlimited_stock" = false);



CREATE INDEX "idx_sales_affiliate_status" ON "public"."sales" USING "btree" ("affiliate_user_id", "status", "company_id");



CREATE INDEX "idx_sales_affiliate_user_id" ON "public"."sales" USING "btree" ("affiliate_user_id");



CREATE INDEX "idx_sales_company_id" ON "public"."sales" USING "btree" ("company_id");



CREATE INDEX "idx_sales_coupon_code" ON "public"."sales" USING "btree" ("coupon_code");



CREATE INDEX "idx_sales_sale_date" ON "public"."sales" USING "btree" ("sale_date");



CREATE INDEX "idx_stage_metrics_affiliate_code" ON "public"."stage_engagement_metrics" USING "btree" ("affiliate_code");



CREATE INDEX "idx_stage_metrics_company_id" ON "public"."stage_engagement_metrics" USING "btree" ("company_id");



CREATE INDEX "idx_stage_metrics_date" ON "public"."stage_engagement_metrics" USING "btree" ("date");



CREATE INDEX "idx_stage_metrics_lookup" ON "public"."stage_engagement_metrics" USING "btree" ("company_id", "affiliate_code", "date");



CREATE INDEX "idx_stage_metrics_stage_id" ON "public"."stage_engagement_metrics" USING "btree" ("stage_id");



CREATE INDEX "idx_thank_you_visits_affiliate_code" ON "public"."thank_you_page_visits" USING "btree" ("affiliate_code");



CREATE INDEX "idx_thank_you_visits_company_id" ON "public"."thank_you_page_visits" USING "btree" ("company_id");



CREATE INDEX "idx_thank_you_visits_date" ON "public"."thank_you_page_visits" USING "btree" ("visited_at");



CREATE INDEX "idx_thank_you_visits_product_id" ON "public"."thank_you_page_visits" USING "btree" ("product_id");



CREATE INDEX "idx_thank_you_visits_redirects" ON "public"."thank_you_page_visits" USING "btree" ("auto_redirect_completed", "manual_redirect_completed");



CREATE INDEX "idx_thank_you_visits_session_id" ON "public"."thank_you_page_visits" USING "btree" ("session_id");



CREATE INDEX "idx_user_audit_logs_created_at" ON "public"."user_audit_logs" USING "btree" ("created_at");



CREATE INDEX "idx_user_audit_logs_user_id" ON "public"."user_audit_logs" USING "btree" ("user_id");



CREATE UNIQUE INDEX "idx_user_bank_details_user_id" ON "public"."user_bank_details" USING "btree" ("user_id");



CREATE UNIQUE INDEX "idx_user_settings_user_id" ON "public"."user_settings" USING "btree" ("user_id");



CREATE INDEX "idx_users_company_id" ON "public"."users" USING "btree" ("company_id");



CREATE UNIQUE INDEX "idx_users_email" ON "public"."users" USING "btree" ("email");



CREATE INDEX "idx_users_role_id" ON "public"."users" USING "btree" ("role_id");



CREATE INDEX "idx_users_status" ON "public"."users" USING "btree" ("status");



CREATE INDEX "idx_withdrawal_requests_company_id" ON "public"."withdrawal_requests" USING "btree" ("company_id");



CREATE INDEX "idx_withdrawal_requests_status" ON "public"."withdrawal_requests" USING "btree" ("status");



CREATE INDEX "idx_withdrawal_requests_user_id" ON "public"."withdrawal_requests" USING "btree" ("user_id");



CREATE OR REPLACE TRIGGER "cleanup_platform_logo_trigger" BEFORE UPDATE ON "public"."platform_settings" FOR EACH ROW EXECUTE FUNCTION "public"."cleanup_old_logo"();



CREATE OR REPLACE TRIGGER "handle_commission_on_sale_with_mlm_trigger" AFTER INSERT OR UPDATE ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."handle_commission_on_sale_with_mlm"();



CREATE OR REPLACE TRIGGER "sync_user_cache_trigger" AFTER INSERT OR UPDATE ON "public"."users" FOR EACH ROW EXECUTE FUNCTION "public"."sync_user_cache"();



CREATE OR REPLACE TRIGGER "trigger_check_coupon_limit" BEFORE UPDATE OF "used_count" ON "public"."coupons" FOR EACH ROW EXECUTE FUNCTION "public"."check_and_deactivate_coupon"();



CREATE OR REPLACE TRIGGER "trigger_create_affiliate_coupon" AFTER INSERT ON "public"."affiliate_links" FOR EACH ROW EXECUTE FUNCTION "public"."create_affiliate_coupon"();



CREATE OR REPLACE TRIGGER "trigger_handle_commission_on_sale_insert" AFTER INSERT ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."handle_commission_on_sale_complete"();



CREATE OR REPLACE TRIGGER "trigger_handle_commission_on_sale_update" AFTER UPDATE ON "public"."sales" FOR EACH ROW WHEN ((("old"."status")::"text" IS DISTINCT FROM ("new"."status")::"text")) EXECUTE FUNCTION "public"."handle_commission_on_sale_complete"();



CREATE OR REPLACE TRIGGER "trigger_notify_commission_earned" AFTER INSERT ON "public"."affiliate_commissions_earned" FOR EACH ROW EXECUTE FUNCTION "public"."notify_commission_earned"();



CREATE OR REPLACE TRIGGER "trigger_notify_new_sale" AFTER INSERT ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."notify_new_sale"();



CREATE OR REPLACE TRIGGER "trigger_notify_payment_processed" AFTER UPDATE ON "public"."affiliate_payments" FOR EACH ROW EXECUTE FUNCTION "public"."notify_payment_processed"();



CREATE OR REPLACE TRIGGER "trigger_notify_sale_confirmed" AFTER UPDATE ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."notify_sale_confirmed"();



CREATE OR REPLACE TRIGGER "trigger_update_affiliate_invitations_updated_at" BEFORE UPDATE ON "public"."affiliate_invitations" FOR EACH ROW EXECUTE FUNCTION "public"."update_affiliate_invitations_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_coupon_usage" AFTER INSERT ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."update_coupon_usage"();



CREATE OR REPLACE TRIGGER "trigger_update_coupon_usage_update" AFTER UPDATE OF "coupon_code" ON "public"."sales" FOR EACH ROW WHEN (((("old"."coupon_code")::"text" IS DISTINCT FROM ("new"."coupon_code")::"text") AND ("new"."coupon_code" IS NOT NULL))) EXECUTE FUNCTION "public"."update_coupon_usage"();



CREATE OR REPLACE TRIGGER "trigger_update_leads_updated_at" BEFORE UPDATE ON "public"."leads" FOR EACH ROW EXECUTE FUNCTION "public"."update_leads_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_product_discount_settings_updated_at" BEFORE UPDATE ON "public"."product_discount_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_product_discount_settings_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_stock_on_sale" BEFORE INSERT ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."update_stock_on_sale"();



CREATE OR REPLACE TRIGGER "update_active_sessions_updated_at" BEFORE UPDATE ON "public"."active_sessions" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_affiliate_addresses_updated_at" BEFORE UPDATE ON "public"."affiliate_addresses" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_affiliate_bank_data_updated_at" BEFORE UPDATE ON "public"."affiliate_bank_data" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_affiliate_profiles_updated_at" BEFORE UPDATE ON "public"."affiliate_profiles" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_company_settings_updated_at_trigger" BEFORE UPDATE ON "public"."company_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_company_settings_updated_at"();



CREATE OR REPLACE TRIGGER "update_company_subscriptions_updated_at" BEFORE UPDATE ON "public"."company_subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."update_company_subscriptions_updated_at"();



CREATE OR REPLACE TRIGGER "update_platform_settings_updated_at" BEFORE UPDATE ON "public"."platform_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_platform_settings_updated_at"();



CREATE OR REPLACE TRIGGER "update_sales_updated_at_trigger" BEFORE UPDATE ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."update_sales_updated_at"();



CREATE OR REPLACE TRIGGER "update_stage_metrics_updated_at" BEFORE UPDATE ON "public"."stage_engagement_metrics" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_subscription_notification_settings_updated_at" BEFORE UPDATE ON "public"."subscription_notification_settings" FOR EACH ROW EXECUTE FUNCTION "public"."update_subscription_notification_settings_updated_at"();



CREATE OR REPLACE TRIGGER "update_user_bank_details_updated_at" BEFORE UPDATE ON "public"."user_bank_details" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_withdrawal_requests_updated_at" BEFORE UPDATE ON "public"."withdrawal_requests" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."active_sessions"
    ADD CONSTRAINT "active_sessions_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."affiliate_addresses"
    ADD CONSTRAINT "affiliate_addresses_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."affiliate_bank_data"
    ADD CONSTRAINT "affiliate_bank_data_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."affiliate_commissions_earned"
    ADD CONSTRAINT "affiliate_commissions_earned_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."affiliate_commissions_earned"
    ADD CONSTRAINT "affiliate_commissions_earned_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."affiliate_links"
    ADD CONSTRAINT "affiliate_links_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."affiliate_links"
    ADD CONSTRAINT "affiliate_links_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."affiliate_links"
    ADD CONSTRAINT "affiliate_links_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."affiliate_payments"
    ADD CONSTRAINT "affiliate_payments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."affiliate_payments"
    ADD CONSTRAINT "affiliate_payments_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."affiliate_payments"
    ADD CONSTRAINT "affiliate_payments_withdrawal_request_id_fkey" FOREIGN KEY ("withdrawal_request_id") REFERENCES "public"."withdrawal_requests"("id");



ALTER TABLE ONLY "public"."affiliate_profiles"
    ADD CONSTRAINT "affiliate_profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."companies"
    ADD CONSTRAINT "companies_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id");



ALTER TABLE ONLY "public"."company_settings"
    ADD CONSTRAINT "company_settings_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_subscriptions"
    ADD CONSTRAINT "company_subscriptions_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_subscriptions"
    ADD CONSTRAINT "company_subscriptions_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_affiliate_user_id_fkey" FOREIGN KEY ("affiliate_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."coupons"
    ADD CONSTRAINT "coupons_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."engagement_events"
    ADD CONSTRAINT "engagement_events_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."affiliate_conversions"
    ADD CONSTRAINT "fk_affiliate_conversions_affiliate_link" FOREIGN KEY ("affiliate_link_id") REFERENCES "public"."affiliate_links"("id");



ALTER TABLE ONLY "public"."affiliate_conversions"
    ADD CONSTRAINT "fk_affiliate_conversions_sale" FOREIGN KEY ("sale_id") REFERENCES "public"."sales"("id");



ALTER TABLE ONLY "public"."affiliate_link_clicks"
    ADD CONSTRAINT "fk_affiliate_link_clicks_affiliate_link" FOREIGN KEY ("affiliate_link_id") REFERENCES "public"."affiliate_links"("id");



ALTER TABLE ONLY "public"."affiliate_links"
    ADD CONSTRAINT "fk_affiliate_links_product" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."affiliate_referrals"
    ADD CONSTRAINT "fk_company" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."company_mlm_levels"
    ADD CONSTRAINT "fk_company_mlm" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."affiliate_referrals"
    ADD CONSTRAINT "fk_referred_user" FOREIGN KEY ("referred_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."affiliate_referrals"
    ADD CONSTRAINT "fk_sponsor_user" FOREIGN KEY ("sponsor_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_affiliate_user_id_fkey" FOREIGN KEY ("affiliate_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."leads"
    ADD CONSTRAINT "leads_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."members"
    ADD CONSTRAINT "members_membership_plan_id_fkey" FOREIGN KEY ("membership_plan_id") REFERENCES "public"."membership_plans"("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY ("order_id") REFERENCES "public"."orders"("id");



ALTER TABLE ONLY "public"."order_items"
    ADD CONSTRAINT "order_items_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_affiliate_user_id_fkey" FOREIGN KEY ("affiliate_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."orders"
    ADD CONSTRAINT "orders_customer_user_id_fkey" FOREIGN KEY ("customer_user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."platform_subscriptions_payments"
    ADD CONSTRAINT "platform_subscriptions_payments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."platform_subscriptions_payments"
    ADD CONSTRAINT "platform_subscriptions_payments_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."subscriptions"("id");



ALTER TABLE ONLY "public"."product_commissions"
    ADD CONSTRAINT "product_commissions_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."product_discount_settings"
    ADD CONSTRAINT "product_discount_settings_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."product_discount_settings"
    ADD CONSTRAINT "product_discount_settings_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."stage_engagement_metrics"
    ADD CONSTRAINT "stage_engagement_metrics_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."thank_you_page_visits"
    ADD CONSTRAINT "thank_you_page_visits_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."thank_you_page_visits"
    ADD CONSTRAINT "thank_you_page_visits_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_audit_logs"
    ADD CONSTRAINT "user_audit_logs_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."user_audit_logs"
    ADD CONSTRAINT "user_audit_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



ALTER TABLE ONLY "public"."user_bank_details"
    ADD CONSTRAINT "user_bank_details_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."users"
    ADD CONSTRAINT "users_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."roles"("id");



ALTER TABLE ONLY "public"."withdrawal_requests"
    ADD CONSTRAINT "withdrawal_requests_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "public"."companies"("id");



ALTER TABLE ONLY "public"."withdrawal_requests"
    ADD CONSTRAINT "withdrawal_requests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id");



CREATE POLICY "Affiliates can create their own withdrawal requests" ON "public"."withdrawal_requests" FOR INSERT WITH CHECK ((("company_id" = "public"."get_current_user_company"()) AND ("user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"())))));



CREATE POLICY "Affiliates can view their own withdrawal requests" ON "public"."withdrawal_requests" FOR SELECT USING ((("company_id" = "public"."get_current_user_company"()) AND ("user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"())))));



CREATE POLICY "Allow all for authenticated users" ON "public"."affiliate_invitations" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Company admin can view own company subscription" ON "public"."company_subscriptions" FOR SELECT USING (("company_id" = ( SELECT "user_cache"."company_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"()))));



CREATE POLICY "Company admins and SuperAdmin can update company withdrawal req" ON "public"."withdrawal_requests" FOR UPDATE USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "Company admins and SuperAdmin can view company withdrawal reque" ON "public"."withdrawal_requests" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "Company admins can insert referrals" ON "public"."affiliate_referrals" FOR INSERT WITH CHECK (((("public"."get_current_user_role"() = 1) OR ("public"."get_current_user_role"() = 2)) AND ("company_id" = "public"."get_current_user_company"())));



CREATE POLICY "Company admins can manage MLM levels" ON "public"."company_mlm_levels" USING (((("public"."get_current_user_role"() = 1) OR ("public"."get_current_user_role"() = 2)) AND ("company_id" = "public"."get_current_user_company"())));



CREATE POLICY "Company admins can view notification settings" ON "public"."subscription_notification_settings" FOR SELECT USING (true);



CREATE POLICY "Company admins can view own notification history" ON "public"."subscription_notifications_history" FOR SELECT USING (("company_id" = ( SELECT "user_cache"."company_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"()))));



CREATE POLICY "Public read for valid invitations" ON "public"."affiliate_invitations" FOR SELECT USING (((("status")::"text" = 'pending'::"text") AND ("expires_at" > "now"()) AND ("used_at" IS NULL)));



CREATE POLICY "Super admin can manage all company subscriptions" ON "public"."company_subscriptions" USING ((EXISTS ( SELECT 1
   FROM "public"."user_cache"
  WHERE (("user_cache"."auth_user_id" = "auth"."uid"()) AND ("user_cache"."role_id" = 1))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_cache"
  WHERE (("user_cache"."auth_user_id" = "auth"."uid"()) AND ("user_cache"."role_id" = 1)))));



CREATE POLICY "Super admin can manage notification settings" ON "public"."subscription_notification_settings" USING ((EXISTS ( SELECT 1
   FROM "public"."user_cache"
  WHERE (("user_cache"."auth_user_id" = "auth"."uid"()) AND ("user_cache"."role_id" = 1)))));



CREATE POLICY "Super admin can view all company subscriptions" ON "public"."company_subscriptions" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."user_cache"
  WHERE (("user_cache"."auth_user_id" = "auth"."uid"()) AND ("user_cache"."role_id" = 1)))));



CREATE POLICY "Super admin can view all notification history" ON "public"."subscription_notifications_history" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."user_cache"
  WHERE (("user_cache"."auth_user_id" = "auth"."uid"()) AND ("user_cache"."role_id" = 1)))));



CREATE POLICY "Users can create active sessions for their company" ON "public"."active_sessions" FOR INSERT WITH CHECK (("company_id" = "public"."get_current_user_company"()));



CREATE POLICY "Users can create clicks for their company" ON "public"."affiliate_link_clicks" FOR INSERT WITH CHECK (("company_id" = "public"."get_current_user_company"()));



CREATE POLICY "Users can create engagement events for their company" ON "public"."engagement_events" FOR INSERT WITH CHECK (("company_id" = "public"."get_current_user_company"()));



CREATE POLICY "Users can only view active sessions from their affiliate codes" ON "public"."active_sessions" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("company_id" = "public"."get_current_user_company"()) AND (("affiliate_code")::"text" = ANY ("public"."get_user_affiliate_codes"())))));



CREATE POLICY "Users can only view engagement events from their affiliate code" ON "public"."engagement_events" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("company_id" = "public"."get_current_user_company"()) AND (("affiliate_code")::"text" = ANY ("public"."get_user_affiliate_codes"())))));



CREATE POLICY "Users can only view their own affiliate clicks" ON "public"."affiliate_link_clicks" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("company_id" = "public"."get_current_user_company"()) AND ("user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"()))))));



CREATE POLICY "Users can only view their own conversions" ON "public"."affiliate_conversions" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("company_id" = "public"."get_current_user_company"()) AND ("user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"()))))));



CREATE POLICY "Users can update active sessions from their affiliate codes" ON "public"."active_sessions" FOR UPDATE USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("company_id" = "public"."get_current_user_company"()) AND (("affiliate_code")::"text" = ANY ("public"."get_user_affiliate_codes"())))));



CREATE POLICY "Users can view MLM levels for their company" ON "public"."company_mlm_levels" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"())));



CREATE POLICY "Users can view referrals in their company" ON "public"."affiliate_referrals" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("company_id" = "public"."get_current_user_company"()) AND (("sponsor_user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"()))) OR ("referred_user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"())))))));



CREATE POLICY "affiliate_commissions_delete_policy" ON "public"."affiliate_commissions_earned" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "affiliate_commissions_insert_policy" ON "public"."affiliate_commissions_earned" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "affiliate_commissions_select_policy" ON "public"."affiliate_commissions_earned" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "affiliate_commissions_update_policy" ON "public"."affiliate_commissions_earned" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "affiliate_invitations_insert_policy" ON "public"."affiliate_invitations" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_cache" "uc"
  WHERE (("uc"."auth_user_id" = "auth"."uid"()) AND ("uc"."role_id" = ANY (ARRAY[1, 2])) AND (("uc"."role_id" = 1) OR (("uc"."role_id" = 2) AND ("uc"."company_id" = "affiliate_invitations"."company_id")))))));



CREATE POLICY "affiliate_invitations_select_policy" ON "public"."affiliate_invitations" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."user_cache" "uc"
  WHERE (("uc"."auth_user_id" = "auth"."uid"()) AND ("uc"."role_id" = ANY (ARRAY[1, 2])) AND (("uc"."role_id" = 1) OR (("uc"."role_id" = 2) AND ("uc"."company_id" = "affiliate_invitations"."company_id")))))));



CREATE POLICY "affiliate_invitations_update_policy" ON "public"."affiliate_invitations" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."user_cache" "uc"
  WHERE (("uc"."auth_user_id" = "auth"."uid"()) AND ("uc"."role_id" = ANY (ARRAY[1, 2])) AND (("uc"."role_id" = 1) OR (("uc"."role_id" = 2) AND ("uc"."company_id" = "affiliate_invitations"."company_id")))))));



CREATE POLICY "affiliate_links_delete_policy" ON "public"."affiliate_links" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "affiliate_links_insert_policy" ON "public"."affiliate_links" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND ("company_id" = "public"."get_current_user_company"())));



CREATE POLICY "affiliate_links_select_policy" ON "public"."affiliate_links" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "affiliate_links_update_policy" ON "public"."affiliate_links" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "affiliate_payments_delete_policy" ON "public"."affiliate_payments" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "affiliate_payments_insert_policy" ON "public"."affiliate_payments" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "affiliate_payments_select_policy" ON "public"."affiliate_payments" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "affiliate_payments_update_policy" ON "public"."affiliate_payments" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "coupons_delete_policy" ON "public"."coupons" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "coupons_insert_policy" ON "public"."coupons" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "coupons_select_policy" ON "public"."coupons" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "coupons_update_policy" ON "public"."coupons" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "leads_delete_policy" ON "public"."leads" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "leads_insert_policy" ON "public"."leads" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND ("company_id" = "public"."get_current_user_company"())));



CREATE POLICY "leads_select_policy" ON "public"."leads" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("company_id" = "public"."get_current_user_company"()) AND ("affiliate_user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"())))))));



CREATE POLICY "leads_update_policy" ON "public"."leads" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "members_delete_policy" ON "public"."members" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "members_insert_policy" ON "public"."members" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "members_select_policy" ON "public"."members" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "members_update_policy" ON "public"."members" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "membership_plans_delete_policy" ON "public"."membership_plans" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "membership_plans_insert_policy" ON "public"."membership_plans" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "membership_plans_select_policy" ON "public"."membership_plans" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "membership_plans_update_policy" ON "public"."membership_plans" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "notifications_delete_policy" ON "public"."notifications" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "notifications_insert_policy" ON "public"."notifications" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "notifications_select_policy" ON "public"."notifications" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "notifications_update_policy" ON "public"."notifications" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "order_items_delete_policy" ON "public"."order_items" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (EXISTS ( SELECT 1
   FROM "public"."orders"
  WHERE (("orders"."id" = "order_items"."order_id") AND ("orders"."company_id" = "public"."get_current_user_company"())))))));



CREATE POLICY "order_items_insert_policy" ON "public"."order_items" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (EXISTS ( SELECT 1
   FROM "public"."orders"
  WHERE (("orders"."id" = "order_items"."order_id") AND ("orders"."company_id" = "public"."get_current_user_company"())))))));



CREATE POLICY "order_items_select_policy" ON "public"."order_items" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (EXISTS ( SELECT 1
   FROM "public"."orders"
  WHERE (("orders"."id" = "order_items"."order_id") AND ("orders"."company_id" = "public"."get_current_user_company"())))))));



CREATE POLICY "order_items_update_policy" ON "public"."order_items" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (EXISTS ( SELECT 1
   FROM "public"."orders"
  WHERE (("orders"."id" = "order_items"."order_id") AND ("orders"."company_id" = "public"."get_current_user_company"())))))));



CREATE POLICY "orders_delete_policy" ON "public"."orders" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "orders_insert_policy" ON "public"."orders" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "orders_select_policy" ON "public"."orders" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "orders_update_policy" ON "public"."orders" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "payment_receipts_delete_policy" ON "public"."payment_receipts" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "payment_receipts_insert_policy" ON "public"."payment_receipts" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "payment_receipts_select_policy" ON "public"."payment_receipts" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "payment_receipts_update_policy" ON "public"."payment_receipts" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "payments_delete_policy" ON "public"."payments" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "payments_insert_policy" ON "public"."payments" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "payments_select_policy" ON "public"."payments" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "payments_update_policy" ON "public"."payments" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "sales_delete_policy" ON "public"."sales" FOR DELETE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "sales_insert_policy" ON "public"."sales" FOR INSERT WITH CHECK (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "sales_select_policy" ON "public"."sales" FOR SELECT USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR ("company_id" = "public"."get_current_user_company"()))));



CREATE POLICY "sales_update_policy" ON "public"."sales" FOR UPDATE USING (("public"."check_company_not_blocked"() AND (("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())))));



CREATE POLICY "stage_metrics_insert_policy" ON "public"."stage_engagement_metrics" FOR INSERT WITH CHECK (("company_id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = (("auth"."jwt"() ->> 'user_id'::"text"))::integer))));



CREATE POLICY "stage_metrics_policy" ON "public"."stage_engagement_metrics" USING (("public"."is_super_admin"() OR ("company_id" = "public"."get_user_company_id"())));



CREATE POLICY "stage_metrics_select_policy" ON "public"."stage_engagement_metrics" FOR SELECT USING (("company_id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = (("auth"."jwt"() ->> 'user_id'::"text"))::integer))));



CREATE POLICY "stage_metrics_update_policy" ON "public"."stage_engagement_metrics" FOR UPDATE USING (("company_id" = ( SELECT "users"."company_id"
   FROM "public"."users"
  WHERE ("users"."id" = (("auth"."jwt"() ->> 'user_id'::"text"))::integer))));



CREATE POLICY "thank_you_visits_policy" ON "public"."thank_you_page_visits" USING (("public"."is_super_admin"() OR ("company_id" = "public"."get_user_company_id"())));



CREATE POLICY "withdrawal_requests_insert_policy" ON "public"."withdrawal_requests" FOR INSERT WITH CHECK ((("public"."get_current_user_role"() = 3) AND ("company_id" = "public"."get_current_user_company"()) AND ("user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"())))));



CREATE POLICY "withdrawal_requests_select_policy" ON "public"."withdrawal_requests" FOR SELECT USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"())) OR (("public"."get_current_user_role"() = 3) AND ("company_id" = "public"."get_current_user_company"()) AND ("user_id" = ( SELECT "user_cache"."user_id"
   FROM "public"."user_cache"
  WHERE ("user_cache"."auth_user_id" = "auth"."uid"()))))));



CREATE POLICY "withdrawal_requests_update_policy" ON "public"."withdrawal_requests" FOR UPDATE USING ((("public"."get_current_user_role"() = 1) OR (("public"."get_current_user_role"() = 2) AND ("company_id" = "public"."get_current_user_company"()))));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."active_sessions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."leads";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."notifications";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."users";






GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";














































































































































































GRANT ALL ON FUNCTION "public"."assign_subscription_to_company"("p_company_id" integer, "p_subscription_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."assign_subscription_to_company"("p_company_id" integer, "p_subscription_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_subscription_to_company"("p_company_id" integer, "p_subscription_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_engagement_score"("p_session_id" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_engagement_score"("p_session_id" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_engagement_score"("p_session_id" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_product_commission"("p_product_name" "text", "p_sale_amount" numeric, "p_company_id" integer, "p_manual_commission" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_product_commission"("p_product_name" "text", "p_sale_amount" numeric, "p_company_id" integer, "p_manual_commission" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_product_commission"("p_product_name" "text", "p_sale_amount" numeric, "p_company_id" integer, "p_manual_commission" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."calculate_subscription_expiry"("p_duration_value" integer, "p_duration_unit" "public"."subscription_duration_unit") TO "anon";
GRANT ALL ON FUNCTION "public"."calculate_subscription_expiry"("p_duration_value" integer, "p_duration_unit" "public"."subscription_duration_unit") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calculate_subscription_expiry"("p_duration_value" integer, "p_duration_unit" "public"."subscription_duration_unit") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_mlm_override_commissions"("p_sale_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_mlm_override_commissions"("p_sale_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_mlm_override_commissions"("p_sale_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cascade_delete_company"("p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cascade_delete_company"("p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cascade_delete_company"("p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cascade_delete_user"("p_user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."cascade_delete_user"("p_user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cascade_delete_user"("p_user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."check_and_deactivate_coupon"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_and_deactivate_coupon"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_and_deactivate_coupon"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_company_not_blocked"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_company_not_blocked"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_company_not_blocked"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_product_stock"("product_id" integer, "required_quantity" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."check_product_stock"("product_id" integer, "required_quantity" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_product_stock"("product_id" integer, "required_quantity" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_old_engagement_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_old_engagement_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_old_engagement_data"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_old_logo"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_old_logo"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_old_logo"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_affiliate_coupon"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_affiliate_coupon"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_affiliate_coupon"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_commission_on_sale"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_commission_on_sale"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_commission_on_sale"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_commission_on_sale_update"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_commission_on_sale_update"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_commission_on_sale_update"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_mlm_override_commissions"("p_sale_id" integer, "p_direct_affiliate_user_id" integer, "p_company_id" integer, "p_sale_amount" numeric, "p_sale_date" timestamp without time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."create_mlm_override_commissions"("p_sale_id" integer, "p_direct_affiliate_user_id" integer, "p_company_id" integer, "p_sale_amount" numeric, "p_sale_date" timestamp without time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_mlm_override_commissions"("p_sale_id" integer, "p_direct_affiliate_user_id" integer, "p_company_id" integer, "p_sale_amount" numeric, "p_sale_date" timestamp without time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_notification"("p_user_id" integer, "p_company_id" integer, "p_title" character varying, "p_message" "text", "p_type" character varying, "p_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."create_notification"("p_user_id" integer, "p_company_id" integer, "p_title" character varying, "p_message" "text", "p_type" character varying, "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_notification"("p_user_id" integer, "p_company_id" integer, "p_title" character varying, "p_message" "text", "p_type" character varying, "p_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."debug_rls_products"() TO "anon";
GRANT ALL ON FUNCTION "public"."debug_rls_products"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."debug_rls_products"() TO "service_role";



GRANT ALL ON FUNCTION "public"."force_delete_company_with_all_dependencies"("p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."force_delete_company_with_all_dependencies"("p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."force_delete_company_with_all_dependencies"("p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."force_delete_user"("p_user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."force_delete_user"("p_user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."force_delete_user"("p_user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_invitation_token"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_invitation_token"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_invitation_token"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_affiliate_upline"("p_affiliate_user_id" integer, "p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_affiliate_upline"("p_affiliate_user_id" integer, "p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_affiliate_upline"("p_affiliate_user_id" integer, "p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_auth_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_auth_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_auth_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_auth_user_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_auth_user_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_auth_user_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_best_affiliate_coupon_optimized"("p_affiliate_user_id" integer, "p_company_id" integer, "p_product_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_best_affiliate_coupon_optimized"("p_affiliate_user_id" integer, "p_company_id" integer, "p_product_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_best_affiliate_coupon_optimized"("p_affiliate_user_id" integer, "p_company_id" integer, "p_product_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_user_company"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_user_company"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_user_company"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_current_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_current_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_current_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_subscription_status"("p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_subscription_status"("p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_subscription_status"("p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_subscriptions_expiring_soon"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_subscriptions_expiring_soon"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_subscriptions_expiring_soon"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_affiliate_codes"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_affiliate_codes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_affiliate_codes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_company"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_company"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_company"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_company_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_company_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_company_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_commission_on_sale"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_commission_on_sale"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_commission_on_sale"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_commission_on_sale_complete"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_commission_on_sale_complete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_commission_on_sale_complete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_commission_on_sale_with_mlm"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_commission_on_sale_with_mlm"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_commission_on_sale_with_mlm"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_super_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."manually_block_subscription"("p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."manually_block_subscription"("p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."manually_block_subscription"("p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_commission_as_paid"("p_commission_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."mark_commission_as_paid"("p_commission_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_commission_as_paid"("p_commission_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_expired_subscriptions"() TO "anon";
GRANT ALL ON FUNCTION "public"."mark_expired_subscriptions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_expired_subscriptions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."mark_subscription_as_paid"("p_company_id" integer, "p_new_expires_at" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."mark_subscription_as_paid"("p_company_id" integer, "p_new_expires_at" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_subscription_as_paid"("p_company_id" integer, "p_new_expires_at" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_commission_earned"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_commission_earned"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_commission_earned"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_new_sale"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_new_sale"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_new_sale"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_payment_processed"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_payment_processed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_payment_processed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_sale_confirmed"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_sale_confirmed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_sale_confirmed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_commissions"("p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_commissions"("p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_commissions"("p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."register_affiliate_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."register_affiliate_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_affiliate_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."register_lead_with_journey"("p_name" "text", "p_email" "text", "p_phone" "text", "p_product_id" integer, "p_product_name" "text", "p_affiliate_code" "text", "p_company_id" integer, "p_ip_address" "text", "p_user_agent" "text", "p_referrer" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_lead_with_journey"("p_name" "text", "p_email" "text", "p_phone" "text", "p_product_id" integer, "p_product_name" "text", "p_affiliate_code" "text", "p_company_id" integer, "p_ip_address" "text", "p_user_agent" "text", "p_referrer" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_lead_with_journey"("p_name" "text", "p_email" "text", "p_phone" "text", "p_product_id" integer, "p_product_name" "text", "p_affiliate_code" "text", "p_company_id" integer, "p_ip_address" "text", "p_user_agent" "text", "p_referrer" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."register_lead_with_journey"("p_name" character varying, "p_email" character varying, "p_phone" character varying, "p_product_id" integer, "p_product_name" character varying, "p_affiliate_code" character varying, "p_company_id" integer, "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_lead_with_journey"("p_name" character varying, "p_email" character varying, "p_phone" character varying, "p_product_id" integer, "p_product_name" character varying, "p_affiliate_code" character varying, "p_company_id" integer, "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_lead_with_journey"("p_name" character varying, "p_email" character varying, "p_phone" character varying, "p_product_id" integer, "p_product_name" character varying, "p_affiliate_code" character varying, "p_company_id" integer, "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "inet") TO "anon";
GRANT ALL ON FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "inet") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "inet") TO "service_role";



GRANT ALL ON FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_notification_shown"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text", "p_ip_address" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."should_show_notification"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."should_show_notification"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."should_show_notification"("p_company_id" integer, "p_notification_type" "text", "p_user_session" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_missing_user_cache"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_missing_user_cache"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_missing_user_cache"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_pending_commissions"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_pending_commissions"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_pending_commissions"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_pending_commissions_complete"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_pending_commissions_complete"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_pending_commissions_complete"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_user_cache"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_user_cache"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_user_cache"() TO "service_role";



GRANT ALL ON FUNCTION "public"."track_affiliate_click"("p_affiliate_code" "text", "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."track_affiliate_click"("p_affiliate_code" "text", "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."track_affiliate_click"("p_affiliate_code" "text", "p_ip_address" "inet", "p_user_agent" "text", "p_referrer" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."track_affiliate_conversion"("p_affiliate_code" "text", "p_sale_id" integer, "p_commission_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."track_affiliate_conversion"("p_affiliate_code" "text", "p_sale_id" integer, "p_commission_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."track_affiliate_conversion"("p_affiliate_code" "text", "p_sale_id" integer, "p_commission_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."ultimate_force_delete_user"("p_user_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."ultimate_force_delete_user"("p_user_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ultimate_force_delete_user"("p_user_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_affiliate_invitations_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_affiliate_invitations_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_affiliate_invitations_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_company_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_company_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_company_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_company_subscriptions_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_company_subscriptions_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_company_subscriptions_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_coupon_usage"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_coupon_usage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_coupon_usage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_leads_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_leads_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_leads_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_platform_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_platform_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_platform_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_product_discount_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_product_discount_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_product_discount_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_sales_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_sales_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_sales_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_stock_on_sale"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_stock_on_sale"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_stock_on_sale"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_subscription_notification_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_subscription_notification_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_subscription_notification_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_no_circular_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."validate_no_circular_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_no_circular_referral"("p_sponsor_user_id" integer, "p_referred_user_id" integer, "p_company_id" integer) TO "service_role";
























GRANT ALL ON TABLE "public"."active_sessions" TO "anon";
GRANT ALL ON TABLE "public"."active_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."active_sessions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."active_sessions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."active_sessions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."active_sessions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_addresses" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_addresses" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_addresses" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_addresses_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_addresses_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_addresses_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_bank_data" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_bank_data" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_bank_data" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_bank_data_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_bank_data_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_bank_data_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_commissions_earned" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_commissions_earned" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_commissions_earned" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_commissions_earned_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_commissions_earned_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_commissions_earned_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_conversions" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_conversions" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_conversions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_conversions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_conversions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_conversions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_invitations" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_invitations" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_invitations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_invitations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_invitations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_invitations_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_link_clicks" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_link_clicks" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_link_clicks" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_link_clicks_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_link_clicks_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_link_clicks_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_links" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_links" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_links" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_links_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_links_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_links_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_payments" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_payments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_payments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_payments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_payments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_profiles" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_profiles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_profiles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_profiles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_profiles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."affiliate_referrals" TO "anon";
GRANT ALL ON TABLE "public"."affiliate_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."affiliate_referrals" TO "service_role";



GRANT ALL ON SEQUENCE "public"."affiliate_referrals_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."affiliate_referrals_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."affiliate_referrals_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."companies" TO "anon";
GRANT ALL ON TABLE "public"."companies" TO "authenticated";
GRANT ALL ON TABLE "public"."companies" TO "service_role";



GRANT ALL ON SEQUENCE "public"."companies_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."companies_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."companies_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."company_mlm_levels" TO "anon";
GRANT ALL ON TABLE "public"."company_mlm_levels" TO "authenticated";
GRANT ALL ON TABLE "public"."company_mlm_levels" TO "service_role";



GRANT ALL ON SEQUENCE "public"."company_mlm_levels_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."company_mlm_levels_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."company_mlm_levels_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."company_settings" TO "anon";
GRANT ALL ON TABLE "public"."company_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."company_settings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."company_settings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."company_settings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."company_settings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."company_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."company_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."company_subscriptions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."company_subscriptions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."company_subscriptions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."company_subscriptions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."coupons" TO "anon";
GRANT ALL ON TABLE "public"."coupons" TO "authenticated";
GRANT ALL ON TABLE "public"."coupons" TO "service_role";



GRANT ALL ON SEQUENCE "public"."coupons_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."coupons_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."coupons_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."engagement_events" TO "anon";
GRANT ALL ON TABLE "public"."engagement_events" TO "authenticated";
GRANT ALL ON TABLE "public"."engagement_events" TO "service_role";



GRANT ALL ON SEQUENCE "public"."engagement_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."engagement_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."engagement_events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."hot_leads" TO "anon";
GRANT ALL ON TABLE "public"."hot_leads" TO "authenticated";
GRANT ALL ON TABLE "public"."hot_leads" TO "service_role";



GRANT ALL ON TABLE "public"."leads" TO "anon";
GRANT ALL ON TABLE "public"."leads" TO "authenticated";
GRANT ALL ON TABLE "public"."leads" TO "service_role";



GRANT ALL ON SEQUENCE "public"."leads_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."leads_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."leads_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."members" TO "anon";
GRANT ALL ON TABLE "public"."members" TO "authenticated";
GRANT ALL ON TABLE "public"."members" TO "service_role";



GRANT ALL ON SEQUENCE "public"."members_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."members_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."members_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."membership_plans" TO "anon";
GRANT ALL ON TABLE "public"."membership_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."membership_plans" TO "service_role";



GRANT ALL ON SEQUENCE "public"."membership_plans_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."membership_plans_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."membership_plans_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."migrations_log" TO "anon";
GRANT ALL ON TABLE "public"."migrations_log" TO "authenticated";
GRANT ALL ON TABLE "public"."migrations_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."migrations_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."migrations_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."migrations_log_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notifications_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."order_items" TO "anon";
GRANT ALL ON TABLE "public"."order_items" TO "authenticated";
GRANT ALL ON TABLE "public"."order_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."order_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."order_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."order_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."orders" TO "anon";
GRANT ALL ON TABLE "public"."orders" TO "authenticated";
GRANT ALL ON TABLE "public"."orders" TO "service_role";



GRANT ALL ON SEQUENCE "public"."orders_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."orders_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."orders_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."payment_receipts" TO "anon";
GRANT ALL ON TABLE "public"."payment_receipts" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_receipts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."payment_receipts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."payment_receipts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."payment_receipts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."payments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."payments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."payments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."platform_settings" TO "anon";
GRANT ALL ON TABLE "public"."platform_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_settings" TO "service_role";



GRANT ALL ON TABLE "public"."platform_subscriptions_payments" TO "anon";
GRANT ALL ON TABLE "public"."platform_subscriptions_payments" TO "authenticated";
GRANT ALL ON TABLE "public"."platform_subscriptions_payments" TO "service_role";



GRANT ALL ON SEQUENCE "public"."platform_subscriptions_payments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."platform_subscriptions_payments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."platform_subscriptions_payments_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."product_commissions" TO "anon";
GRANT ALL ON TABLE "public"."product_commissions" TO "authenticated";
GRANT ALL ON TABLE "public"."product_commissions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."product_commissions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."product_commissions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."product_commissions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."product_discount_settings" TO "anon";
GRANT ALL ON TABLE "public"."product_discount_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."product_discount_settings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."product_discount_settings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."product_discount_settings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."product_discount_settings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."products_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."real_time_engagement_metrics" TO "anon";
GRANT ALL ON TABLE "public"."real_time_engagement_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."real_time_engagement_metrics" TO "service_role";



GRANT ALL ON TABLE "public"."recent_engagement_events" TO "anon";
GRANT ALL ON TABLE "public"."recent_engagement_events" TO "authenticated";
GRANT ALL ON TABLE "public"."recent_engagement_events" TO "service_role";



GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."roles_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sales" TO "anon";
GRANT ALL ON TABLE "public"."sales" TO "authenticated";
GRANT ALL ON TABLE "public"."sales" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sales_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sales_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sales_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."stage_engagement_metrics" TO "anon";
GRANT ALL ON TABLE "public"."stage_engagement_metrics" TO "authenticated";
GRANT ALL ON TABLE "public"."stage_engagement_metrics" TO "service_role";



GRANT ALL ON SEQUENCE "public"."stage_engagement_metrics_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."stage_engagement_metrics_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."stage_engagement_metrics_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_notification_settings" TO "anon";
GRANT ALL ON TABLE "public"."subscription_notification_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_notification_settings" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_notifications_history" TO "anon";
GRANT ALL ON TABLE "public"."subscription_notifications_history" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_notifications_history" TO "service_role";



GRANT ALL ON SEQUENCE "public"."subscription_notifications_history_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."subscription_notifications_history_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."subscription_notifications_history_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."subscriptions" TO "service_role";



GRANT ALL ON SEQUENCE "public"."subscriptions_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."subscriptions_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."subscriptions_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."thank_you_page_visits" TO "anon";
GRANT ALL ON TABLE "public"."thank_you_page_visits" TO "authenticated";
GRANT ALL ON TABLE "public"."thank_you_page_visits" TO "service_role";



GRANT ALL ON TABLE "public"."thank_you_page_stats" TO "anon";
GRANT ALL ON TABLE "public"."thank_you_page_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."thank_you_page_stats" TO "service_role";



GRANT ALL ON SEQUENCE "public"."thank_you_page_visits_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."thank_you_page_visits_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."thank_you_page_visits_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."user_audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."user_audit_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."user_audit_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_audit_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_audit_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_bank_details" TO "anon";
GRANT ALL ON TABLE "public"."user_bank_details" TO "authenticated";
GRANT ALL ON TABLE "public"."user_bank_details" TO "service_role";



GRANT ALL ON SEQUENCE "public"."user_bank_details_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_bank_details_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_bank_details_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."user_cache" TO "anon";
GRANT ALL ON TABLE "public"."user_cache" TO "authenticated";
GRANT ALL ON TABLE "public"."user_cache" TO "service_role";



GRANT ALL ON TABLE "public"."user_settings" TO "anon";
GRANT ALL ON TABLE "public"."user_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."user_settings" TO "service_role";



GRANT ALL ON SEQUENCE "public"."user_settings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."user_settings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."user_settings_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."users" TO "anon";
GRANT ALL ON TABLE "public"."users" TO "authenticated";
GRANT ALL ON TABLE "public"."users" TO "service_role";



GRANT ALL ON SEQUENCE "public"."users_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."users_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."users_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."withdrawal_requests" TO "anon";
GRANT ALL ON TABLE "public"."withdrawal_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."withdrawal_requests" TO "service_role";



GRANT ALL ON SEQUENCE "public"."withdrawal_requests_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."withdrawal_requests_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."withdrawal_requests_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































