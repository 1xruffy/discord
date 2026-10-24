-- ==============================================================================
-- MEMOCORD ONE-TIME DATA MIGRATION SCRIPT
-- Migrates JSON state from public.state (row id=1) to Relational Tables
-- Run this AFTER running schema.sql in Supabase SQL Editor.
-- ==============================================================================

DO $$
DECLARE
  v_state RECORD;
  v_data JSONB;
  
  -- User iterator variables
  v_uname TEXT;
  v_udata JSONB;
  v_auth_uid UUID;
  
  -- Server iterator variables
  v_sid TEXT;
  v_sdata JSONB;
  v_role JSONB;
  v_member TEXT;
  v_ch JSONB;
  v_cid TEXT;
  v_msgs JSONB;
  v_msg JSONB;
  v_ban JSONB;
  v_inv JSONB;
  v_audit JSONB;
  
  -- DM & Group iterator variables
  v_dm_key TEXT;
  v_dm_msgs JSONB;
  v_dm_msg JSONB;
  v_gid TEXT;
  v_gdata JSONB;
  
  -- Misc items
  v_report JSONB;
  v_warn_u TEXT;
  v_warn_list JSONB;
  v_warn JSONB;
  v_badge_key TEXT;
  v_badge_val JSONB;
  v_gif JSONB;
  
  v_migrated_users INT := 0;
  v_migrated_servers INT := 0;
  v_migrated_msgs INT := 0;
  v_migrated_dms INT := 0;
BEGIN
  RAISE NOTICE 'Starting Memocord State Migration to Relational Tables...';

  -- 1. Fetch state row
  SELECT * INTO v_state FROM public.state WHERE id = 1 LIMIT 1;
  IF v_state IS NULL OR v_state.data IS NULL THEN
    RAISE NOTICE 'No state data found in public.state (id=1). Skipping migration.';
    RETURN;
  END IF;

  v_data := v_state.data;

  -- ----------------------------------------------------------------------------
  -- 2. Migrate Users -> public.profiles
  -- ----------------------------------------------------------------------------
  RAISE NOTICE 'Migrating user profiles...';
  FOR v_uname, v_udata IN SELECT * FROM jsonb_each(COALESCE(v_data->'users', '{}'::jsonb))
  LOOP
    -- Attempt to find existing auth.users record by username in user_metadata or email
    SELECT id INTO v_auth_uid
    FROM auth.users
    WHERE raw_user_meta_data->>'username' = v_uname
       OR email = LOWER(v_uname) || '@memocord.app'
    LIMIT 1;

    IF v_auth_uid IS NULL THEN
      v_auth_uid := gen_random_uuid();
    END IF;

    INSERT INTO public.profiles (
      id,
      username,
      display,
      avatar,
      banner,
      banner_color,
      accent_color,
      status,
      presence,
      bio,
      joined_at,
      is_banned,
      is_admin,
      badges,
      friends,
      freq_in,
      freq_out,
      blocked,
      nameplate,
      settings,
      muted_servers,
      ch_read,
      dm_read,
      closed_dms
    ) VALUES (
      v_auth_uid,
      v_uname,
      COALESCE(v_udata->>'display', v_uname),
      COALESCE(v_udata->>'avatar', ''),
      COALESCE(v_udata->>'banner', ''),
      COALESCE(v_udata->>'bc', ''),
      COALESCE(v_udata->>'accent', '#ff5a36'),
      COALESCE(v_udata->>'status', ''),
      COALESCE(v_udata->>'presence', 'online'),
      COALESCE(v_udata->>'bio', ''),
      CASE 
        WHEN (v_udata->>'joined') IS NOT NULL AND (v_udata->>'joined')::bigint > 0 
        THEN to_timestamp(((v_udata->>'joined')::bigint)/1000.0)
        ELSE now()
      END,
      COALESCE((v_udata->>'banned')::int > 0, false),
      (v_uname = '981'),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'b', '[]'::jsonb))),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'friends', '[]'::jsonb))),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'freq_in', '[]'::jsonb))),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'freq_out', '[]'::jsonb))),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'blocked', '[]'::jsonb))),
      COALESCE(v_udata->>'plate', ''),
      COALESCE(v_udata->'set', '{"sound":true,"compact":false,"fs":15,"reduce":false,"dev":false,"theme":"dark"}'::jsonb),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'mutedServers', '[]'::jsonb))),
      COALESCE(v_udata->'chRead', '{}'::jsonb),
      COALESCE(v_udata->'read', '{}'::jsonb),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_udata->'closedDMs', '[]'::jsonb)))
    )
    ON CONFLICT (username) DO UPDATE SET
      display = EXCLUDED.display,
      avatar = EXCLUDED.avatar,
      banner = EXCLUDED.banner,
      banner_color = EXCLUDED.banner_color,
      accent_color = EXCLUDED.accent_color,
      status = EXCLUDED.status,
      presence = EXCLUDED.presence,
      bio = EXCLUDED.bio,
      is_banned = EXCLUDED.is_banned,
      is_admin = EXCLUDED.is_admin,
      badges = EXCLUDED.badges,
      friends = EXCLUDED.friends,
      freq_in = EXCLUDED.freq_in,
      freq_out = EXCLUDED.freq_out,
      blocked = EXCLUDED.blocked,
      nameplate = EXCLUDED.nameplate,
      settings = EXCLUDED.settings,
      muted_servers = EXCLUDED.muted_servers,
      ch_read = EXCLUDED.ch_read,
      dm_read = EXCLUDED.dm_read,
      closed_dms = EXCLUDED.closed_dms;

    v_migrated_users := v_migrated_users + 1;
  END LOOP;
  RAISE NOTICE 'Migrated % profiles.', v_migrated_users;

  -- ----------------------------------------------------------------------------
  -- 3. Migrate Servers -> public.servers
  -- ----------------------------------------------------------------------------
  RAISE NOTICE 'Migrating servers...';
  FOR v_sid, v_sdata IN SELECT * FROM jsonb_each(COALESCE(v_data->'servers', '{}'::jsonb))
  LOOP
    -- Ensure server owner profile exists
    INSERT INTO public.profiles (username, display)
    VALUES (COALESCE(v_sdata->>'owner', '981'), COALESCE(v_sdata->>'owner', '981'))
    ON CONFLICT (username) DO NOTHING;

    INSERT INTO public.servers (
      id,
      name,
      owner,
      description,
      icon,
      banner,
      is_community,
      invite,
      created_at,
      emojis,
      powers,
      bots
    ) VALUES (
      v_sid,
      COALESCE(v_sdata->>'name', v_sid),
      COALESCE(v_sdata->>'owner', '981'),
      COALESCE(v_sdata->>'desc', ''),
      COALESCE(v_sdata->>'icon', ''),
      COALESCE(v_sdata->>'banner', ''),
      COALESCE((v_sdata->>'community')::boolean, false),
      COALESCE(v_sdata->>'invite', ''),
      CASE 
        WHEN (v_sdata->>'createdAt') IS NOT NULL AND (v_sdata->>'createdAt')::bigint > 0 
        THEN to_timestamp(((v_sdata->>'createdAt')::bigint)/1000.0)
        ELSE now()
      END,
      COALESCE(v_sdata->'emojis', '{}'::jsonb),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_sdata->'powers', '[]'::jsonb))),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_sdata->'bots', '[]'::jsonb)))
    )
    ON CONFLICT (id) DO UPDATE SET
      name = EXCLUDED.name,
      owner = EXCLUDED.owner,
      description = EXCLUDED.description,
      icon = EXCLUDED.icon,
      banner = EXCLUDED.banner,
      is_community = EXCLUDED.is_community,
      invite = EXCLUDED.invite,
      emojis = EXCLUDED.emojis,
      powers = EXCLUDED.powers,
      bots = EXCLUDED.bots;

    -- Migrate Server Roles
    FOR v_role IN SELECT * FROM jsonb_array_elements(COALESCE(v_sdata->'roles', '[]'::jsonb))
    LOOP
      INSERT INTO public.server_roles (
        id,
        server_id,
        name,
        color,
        manage_channels,
        manage_messages,
        kick_members,
        ban_members,
        mention_everyone,
        ch_overrides
      ) VALUES (
        v_role->>'id',
        v_sid,
        COALESCE(v_role->>'name', 'Role'),
        COALESCE(v_role->>'color', '#a89b94'),
        COALESCE((v_role->>'manage_channels')::boolean, false),
        COALESCE((v_role->>'manage_messages')::boolean, false),
        COALESCE((v_role->>'kick_members')::boolean, false),
        COALESCE((v_role->>'ban_members')::boolean, false),
        COALESCE((v_role->>'mention_everyone')::boolean, false),
        COALESCE(v_role->'ch', '{}'::jsonb)
      )
      ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        color = EXCLUDED.color,
        manage_channels = EXCLUDED.manage_channels,
        manage_messages = EXCLUDED.manage_messages,
        kick_members = EXCLUDED.kick_members,
        ban_members = EXCLUDED.ban_members,
        mention_everyone = EXCLUDED.mention_everyone,
        ch_overrides = EXCLUDED.ch_overrides;
    END LOOP;

    -- Migrate Server Members
    FOR v_member IN SELECT * FROM jsonb_array_elements_text(COALESCE(v_sdata->'members', '[]'::jsonb))
    LOOP
      -- Ensure profile exists
      INSERT INTO public.profiles (username, display)
      VALUES (v_member, v_member)
      ON CONFLICT (username) DO NOTHING;

      INSERT INTO public.server_members (
        server_id,
        username,
        is_verified,
        roles
      ) VALUES (
        v_sid,
        v_member,
        COALESCE((v_sdata->'ver' @> to_jsonb(v_member)), false),
        ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_sdata->'mroles'->v_member, '[]'::jsonb)))
      )
      ON CONFLICT (server_id, username) DO UPDATE SET
        is_verified = EXCLUDED.is_verified,
        roles = EXCLUDED.roles;
    END LOOP;

    -- Migrate Server Channels
    FOR v_ch IN SELECT * FROM jsonb_array_elements(COALESCE(v_sdata->'ch', '[]'::jsonb))
    LOOP
      INSERT INTO public.channels (
        id,
        server_id,
        name,
        type,
        category,
        is_locked,
        topic,
        slowmode
      ) VALUES (
        v_ch->>'id',
        v_sid,
        COALESCE(v_ch->>'n', v_ch->>'id'),
        COALESCE(v_ch->>'t', 't'),
        COALESCE(v_ch->>'cat', 'TEXT'),
        COALESCE((v_ch->>'lock')::boolean, false),
        COALESCE(v_ch->>'topic', ''),
        COALESCE((v_ch->>'slowmode')::int, 0)
      )
      ON CONFLICT (server_id, id) DO UPDATE SET
        name = EXCLUDED.name,
        type = EXCLUDED.type,
        category = EXCLUDED.category,
        is_locked = EXCLUDED.is_locked,
        topic = EXCLUDED.topic,
        slowmode = EXCLUDED.slowmode;
    END LOOP;

    -- Migrate Channel Messages
    FOR v_cid, v_msgs IN SELECT * FROM jsonb_each(COALESCE(v_sdata->'msgs', '{}'::jsonb))
    LOOP
      -- Ensure channel exists
      INSERT INTO public.channels (id, server_id, name)
      VALUES (v_cid, v_sid, v_cid)
      ON CONFLICT (server_id, id) DO NOTHING;

      FOR v_msg IN SELECT * FROM jsonb_array_elements(COALESCE(v_msgs, '[]'::jsonb))
      LOOP
        -- Ensure author profile exists
        IF v_msg->>'u' IS NOT NULL THEN
          INSERT INTO public.profiles (username, display)
          VALUES (v_msg->>'u', v_msg->>'u')
          ON CONFLICT (username) DO NOTHING;
        END IF;

        INSERT INTO public.messages (
          server_id,
          channel_id,
          username,
          content,
          image_url,
          created_ts,
          created_at,
          edited_ts,
          is_pinned,
          reply_to,
          embed,
          button,
          giveaway,
          reactions,
          mentions,
          everyone_ping
        ) VALUES (
          v_sid,
          v_cid,
          COALESCE(v_msg->>'u', 'Memocord'),
          COALESCE(v_msg->>'x', ''),
          COALESCE(v_msg->>'img', ''),
          (v_msg->>'ts')::bigint,
          to_timestamp(((v_msg->>'ts')::bigint)/1000.0),
          (v_msg->>'ed')::bigint,
          COALESCE((v_msg->>'pin')::boolean, false),
          v_msg->'re',
          v_msg->'em',
          v_msg->>'btn',
          v_msg->'g',
          COALESCE(v_msg->'r', '{}'::jsonb),
          ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_msg->'mentions', '[]'::jsonb))),
          COALESCE((v_msg->>'everyonePing')::boolean, false)
        );

        v_migrated_msgs := v_migrated_msgs + 1;
      END LOOP;
    END LOOP;

    -- Migrate Server Bans
    FOR v_ban IN SELECT * FROM jsonb_array_elements(COALESCE(v_sdata->'bans', '[]'::jsonb))
    LOOP
      IF jsonb_typeof(v_ban) = 'string' THEN
        INSERT INTO public.server_bans (server_id, username, banned_by, reason)
        VALUES (v_sid, v_ban#>>'{}', COALESCE(v_sdata->>'owner', '981'), 'Banned')
        ON CONFLICT (server_id, username) DO NOTHING;
      ELSE
        INSERT INTO public.server_bans (server_id, username, banned_by, reason, created_at)
        VALUES (
          v_sid,
          v_ban->>'u',
          COALESCE(v_ban->>'by', v_sdata->>'owner'),
          COALESCE(v_ban->>'reason', 'Banned'),
          CASE WHEN (v_ban->>'ts') IS NOT NULL THEN to_timestamp(((v_ban->>'ts')::bigint)/1000.0) ELSE now() END
        )
        ON CONFLICT (server_id, username) DO NOTHING;
      END IF;
    END LOOP;

    -- Migrate Server Invites
    FOR v_inv IN SELECT * FROM jsonb_array_elements(COALESCE(v_sdata->'invites', '[]'::jsonb))
    LOOP
      INSERT INTO public.server_invites (
        code,
        server_id,
        created_by,
        created_at,
        expires_at,
        max_uses,
        uses
      ) VALUES (
        v_inv->>'code',
        v_sid,
        COALESCE(v_inv->>'by', v_sdata->>'owner'),
        CASE WHEN (v_inv->>'createdAt') IS NOT NULL THEN to_timestamp(((v_inv->>'createdAt')::bigint)/1000.0) ELSE now() END,
        CASE WHEN (v_inv->>'expiresAt')::bigint > 0 THEN to_timestamp(((v_inv->>'expiresAt')::bigint)/1000.0) ELSE NULL END,
        COALESCE((v_inv->>'maxUses')::int, 0),
        COALESCE((v_inv->>'uses')::int, 0)
      )
      ON CONFLICT (code) DO UPDATE SET
        uses = EXCLUDED.uses,
        max_uses = EXCLUDED.max_uses,
        expires_at = EXCLUDED.expires_at;
    END LOOP;

    -- Migrate Server Audit Log
    FOR v_audit IN SELECT * FROM jsonb_array_elements(COALESCE(v_sdata->'auditLog', '[]'::jsonb))
    LOOP
      INSERT INTO public.server_audit_log (
        server_id,
        actor,
        action,
        target,
        created_at
      ) VALUES (
        v_sid,
        COALESCE(v_audit->>'by', v_sdata->>'owner'),
        COALESCE(v_audit->>'action', 'Action'),
        COALESCE(v_audit->>'target', ''),
        CASE WHEN (v_audit->>'ts') IS NOT NULL THEN to_timestamp(((v_audit->>'ts')::bigint)/1000.0) ELSE now() END
      );
    END LOOP;

    v_migrated_servers := v_migrated_servers + 1;
  END LOOP;
  RAISE NOTICE 'Migrated % servers and % server messages.', v_migrated_servers, v_migrated_msgs;

  -- ----------------------------------------------------------------------------
  -- 4. Migrate Groups -> public.groups
  -- ----------------------------------------------------------------------------
  RAISE NOTICE 'Migrating group DMs...';
  FOR v_gid, v_gdata IN SELECT * FROM jsonb_each(COALESCE(v_data->'groups', '{}'::jsonb))
  LOOP
    INSERT INTO public.groups (
      id,
      name,
      owner,
      members
    ) VALUES (
      v_gid,
      COALESCE(v_gdata->>'name', 'Group'),
      COALESCE(v_gdata->>'owner', '981'),
      ARRAY(SELECT jsonb_array_elements_text(COALESCE(v_gdata->'members', '[]'::jsonb)))
    )
    ON CONFLICT (id) DO UPDATE SET
      name = EXCLUDED.name,
      owner = EXCLUDED.owner,
      members = EXCLUDED.members;

    -- Migrate group messages into public.dms
    FOR v_dm_msg IN SELECT * FROM jsonb_array_elements(COALESCE(v_gdata->'msgs', '[]'::jsonb))
    LOOP
      INSERT INTO public.dms (
        channel_key,
        sender,
        content,
        image_url,
        created_ts,
        created_at,
        edited_ts,
        is_pinned,
        reply_to,
        reactions
      ) VALUES (
        v_gid,
        COALESCE(v_dm_msg->>'u', 'Memocord'),
        COALESCE(v_dm_msg->>'x', ''),
        COALESCE(v_dm_msg->>'img', ''),
        (v_dm_msg->>'ts')::bigint,
        to_timestamp(((v_dm_msg->>'ts')::bigint)/1000.0),
        (v_dm_msg->>'ed')::bigint,
        COALESCE((v_dm_msg->>'pin')::boolean, false),
        v_dm_msg->'re',
        COALESCE(v_dm_msg->'r', '{}'::jsonb)
      );
      v_migrated_dms := v_migrated_dms + 1;
    END LOOP;
  END LOOP;

  -- ----------------------------------------------------------------------------
  -- 5. Migrate 1-on-1 Direct Messages -> public.dms
  -- ----------------------------------------------------------------------------
  RAISE NOTICE 'Migrating 1-on-1 DMs...';
  FOR v_dm_key, v_dm_msgs IN SELECT * FROM jsonb_each(COALESCE(v_data->'dms', '{}'::jsonb))
  LOOP
    FOR v_dm_msg IN SELECT * FROM jsonb_array_elements(COALESCE(v_dm_msgs, '[]'::jsonb))
    LOOP
      INSERT INTO public.dms (
        channel_key,
        sender,
        content,
        image_url,
        created_ts,
        created_at,
        edited_ts,
        is_pinned,
        reply_to,
        reactions
      ) VALUES (
        v_dm_key,
        COALESCE(v_dm_msg->>'u', 'Memocord'),
        COALESCE(v_dm_msg->>'x', ''),
        COALESCE(v_dm_msg->>'img', ''),
        (v_dm_msg->>'ts')::bigint,
        to_timestamp(((v_dm_msg->>'ts')::bigint)/1000.0),
        (v_dm_msg->>'ed')::bigint,
        COALESCE((v_dm_msg->>'pin')::boolean, false),
        v_dm_msg->'re',
        COALESCE(v_dm_msg->'r', '{}'::jsonb)
      );
      v_migrated_dms := v_migrated_dms + 1;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'Migrated % direct and group messages.', v_migrated_dms;

  -- ----------------------------------------------------------------------------
  -- 6. Migrate Reports, Warnings, Badges, GIFs, App Config
  -- ----------------------------------------------------------------------------
  RAISE NOTICE 'Migrating reports, warnings, badges, gifs...';
  
  -- Reports
  FOR v_report IN SELECT * FROM jsonb_array_elements(COALESCE(v_data->'reports', '[]'::jsonb))
  LOOP
    INSERT INTO public.reports (id, reported_by, username, reason, server_or_context, created_ts, created_at)
    VALUES (
      COALESCE(v_report->>'id', gen_random_uuid()::text),
      COALESCE(v_report->>'by', 'unknown'),
      COALESCE(v_report->>'u', 'unknown'),
      COALESCE(v_report->>'why', 'Reported'),
      COALESCE(v_report->>'at', ''),
      COALESCE((v_report->>'ts')::bigint, 0),
      CASE WHEN (v_report->>'ts') IS NOT NULL THEN to_timestamp(((v_report->>'ts')::bigint)/1000.0) ELSE now() END
    )
    ON CONFLICT (id) DO NOTHING;
  END LOOP;

  -- User Warnings
  FOR v_warn_u, v_warn_list IN SELECT * FROM jsonb_each(COALESCE(v_data->'userWarnings', '{}'::jsonb))
  LOOP
    FOR v_warn IN SELECT * FROM jsonb_array_elements(COALESCE(v_warn_list, '[]'::jsonb))
    LOOP
      INSERT INTO public.user_warnings (id, username, issued_by, reason, created_ts, created_at)
      VALUES (
        COALESCE(v_warn->>'id', gen_random_uuid()::text),
        v_warn_u,
        COALESCE(v_warn->>'by', '981'),
        COALESCE(v_warn->>'reason', 'Warning'),
        COALESCE((v_warn->>'ts')::bigint, 0),
        CASE WHEN (v_warn->>'ts') IS NOT NULL THEN to_timestamp(((v_warn->>'ts')::bigint)/1000.0) ELSE now() END
      )
      ON CONFLICT (id) DO NOTHING;
    END LOOP;
  END LOOP;

  -- Custom Badges
  FOR v_badge_key, v_badge_val IN SELECT * FROM jsonb_each(COALESCE(v_data->'customBadges', '{}'::jsonb))
  LOOP
    INSERT INTO public.custom_badges (key, symbol, color, label)
    VALUES (
      v_badge_key,
      COALESCE(v_badge_val->>0, 'star'),
      COALESCE(v_badge_val->>1, '#5865f2'),
      COALESCE(v_badge_val->>2, v_badge_key)
    )
    ON CONFLICT (key) DO UPDATE SET
      symbol = EXCLUDED.symbol,
      color = EXCLUDED.color,
      label = EXCLUDED.label;
  END LOOP;

  -- GIFs
  FOR v_gif IN SELECT * FROM jsonb_array_elements(COALESCE(v_data->'gifs', '[]'::jsonb))
  LOOP
    INSERT INTO public.gifs (url, description, added_by)
    VALUES (
      v_gif->>'url',
      COALESCE(v_gif->>'desc', ''),
      COALESCE(v_gif->>'by', '981')
    );
  END LOOP;

  -- App Config (Update Log)
  IF v_data->'updateLog' IS NOT NULL THEN
    INSERT INTO public.app_config (key, value)
    VALUES ('updateLog', v_data->'updateLog')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  END IF;

  RAISE NOTICE '==================================================';
  RAISE NOTICE 'MIGRATION COMPLETE!';
  RAISE NOTICE 'Migrated: % users, % servers, % messages, % DMs', 
    v_migrated_users, v_migrated_servers, v_migrated_msgs, v_migrated_dms;
  RAISE NOTICE '==================================================';
END $$;
