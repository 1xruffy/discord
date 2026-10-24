-- ==============================================================================
-- MEMOCORD RELATIONAL SCHEMA & ROW LEVEL SECURITY (RLS)
-- Phase 7: Comprehensive Database Security & Multi-table Architecture
-- ==============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ------------------------------------------------------------------------------
-- 1. Helper Security Functions (Used across RLS policies)
-- ------------------------------------------------------------------------------

-- Get the authenticated username from JWT metadata or auth.users
CREATE OR REPLACE FUNCTION public.current_username()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT COALESCE(
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb -> 'user_metadata' ->> 'username'),
    (SELECT raw_user_meta_data->>'username' FROM auth.users WHERE id = auth.uid())
  );
$$;

-- Check if current authenticated user is a platform admin (e.g. Founder/Owner '981')
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT COALESCE(
    public.current_username() = '981' OR
    EXISTS (SELECT 1 FROM public.profiles WHERE username = public.current_username() AND is_admin = true),
    false
  );
$$;

-- ------------------------------------------------------------------------------
-- 2. Profiles Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT UNIQUE NOT NULL,
  display TEXT NOT NULL,
  avatar TEXT DEFAULT '',
  banner TEXT DEFAULT '',
  banner_color TEXT DEFAULT '',
  accent_color TEXT DEFAULT '#ff5a36',
  status TEXT DEFAULT '',
  presence TEXT DEFAULT 'online' CHECK (presence IN ('online', 'idle', 'dnd', 'invisible', 'offline')),
  bio TEXT DEFAULT '',
  joined_at TIMESTAMPTZ DEFAULT now(),
  is_banned BOOLEAN DEFAULT false,
  is_admin BOOLEAN DEFAULT false,
  badges TEXT[] DEFAULT '{}',
  friends TEXT[] DEFAULT '{}',
  freq_in TEXT[] DEFAULT '{}',
  freq_out TEXT[] DEFAULT '{}',
  blocked TEXT[] DEFAULT '{}',
  nameplate TEXT DEFAULT '',
  settings JSONB DEFAULT '{"sound":true,"compact":false,"fs":15,"reduce":false,"dev":false,"theme":"dark"}'::jsonb,
  muted_servers TEXT[] DEFAULT '{}',
  ch_read JSONB DEFAULT '{}'::jsonb,
  dm_read JSONB DEFAULT '{}'::jsonb,
  closed_dms TEXT[] DEFAULT '{}'
);

-- ------------------------------------------------------------------------------
-- 3. Servers Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.servers (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  description TEXT DEFAULT '',
  icon TEXT DEFAULT '',
  banner TEXT DEFAULT '',
  is_community BOOLEAN DEFAULT false,
  invite TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now(),
  emojis JSONB DEFAULT '{}'::jsonb,
  powers TEXT[] DEFAULT '{}',
  bots TEXT[] DEFAULT '{}'
);

-- ------------------------------------------------------------------------------
-- 4. Server Roles Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.server_roles (
  id TEXT PRIMARY KEY,
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  color TEXT DEFAULT '#a89b94',
  position INT DEFAULT 0,
  manage_channels BOOLEAN DEFAULT false,
  manage_messages BOOLEAN DEFAULT false,
  kick_members BOOLEAN DEFAULT false,
  ban_members BOOLEAN DEFAULT false,
  mention_everyone BOOLEAN DEFAULT false,
  ch_overrides JSONB DEFAULT '{}'::jsonb, -- { [cid]: { v: 0/1, s: 0/1 } }
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ------------------------------------------------------------------------------
-- 5. Server Members Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.server_members (
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  username TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE ON DELETE CASCADE,
  joined_at TIMESTAMPTZ DEFAULT now(),
  is_verified BOOLEAN DEFAULT false,
  roles TEXT[] DEFAULT '{}', -- array of role IDs
  PRIMARY KEY (server_id, username)
);

-- ------------------------------------------------------------------------------
-- 6. Server Bans Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.server_bans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  username TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE ON DELETE CASCADE,
  banned_by TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  reason TEXT DEFAULT 'Banned by moderator',
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE (server_id, username)
);

-- ------------------------------------------------------------------------------
-- 7. Server Invites Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.server_invites (
  code TEXT PRIMARY KEY,
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  created_by TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  created_at TIMESTAMPTZ DEFAULT now(),
  expires_at TIMESTAMPTZ,
  max_uses INT DEFAULT 0,
  uses INT DEFAULT 0
);

-- ------------------------------------------------------------------------------
-- 8. Server Audit Log Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.server_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  actor TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  action TEXT NOT NULL,
  target TEXT DEFAULT '',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ------------------------------------------------------------------------------
-- 9. Channels Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.channels (
  id TEXT NOT NULL,
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  type TEXT DEFAULT 't' CHECK (type IN ('t', 'v')),
  category TEXT DEFAULT 'TEXT',
  is_locked BOOLEAN DEFAULT false,
  topic TEXT DEFAULT '',
  slowmode INT DEFAULT 0,
  position INT DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT now(),
  PRIMARY KEY (server_id, id)
);

-- ------------------------------------------------------------------------------
-- 10. Messages Table (Server Channels)
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  server_id TEXT NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
  channel_id TEXT NOT NULL,
  username TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  content TEXT DEFAULT '',
  image_url TEXT DEFAULT '',
  created_ts BIGINT NOT NULL,
  edited_ts BIGINT,
  is_pinned BOOLEAN DEFAULT false,
  reply_to JSONB,
  embed JSONB,
  button TEXT,
  giveaway JSONB,
  reactions JSONB DEFAULT '{}'::jsonb,
  mentions TEXT[] DEFAULT '{}',
  everyone_ping BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  FOREIGN KEY (server_id, channel_id) REFERENCES public.channels(server_id, id) ON DELETE CASCADE
);

-- ------------------------------------------------------------------------------
-- 11. Direct Messages & Group Messages Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_key TEXT NOT NULL, -- 'userA|userB' (alphabetical) or 'g<id>'
  sender TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  content TEXT DEFAULT '',
  image_url TEXT DEFAULT '',
  created_ts BIGINT NOT NULL,
  edited_ts BIGINT,
  is_pinned BOOLEAN DEFAULT false,
  reply_to JSONB,
  reactions JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ------------------------------------------------------------------------------
-- 12. Groups Table
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  members TEXT[] NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ------------------------------------------------------------------------------
-- 13. Reports, Warnings, Badges, GIFs
-- ------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.reports (
  id TEXT PRIMARY KEY,
  reported_by TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  username TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  reason TEXT NOT NULL,
  server_or_context TEXT DEFAULT '',
  created_ts BIGINT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.user_warnings (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE ON DELETE CASCADE,
  issued_by TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  reason TEXT NOT NULL,
  created_ts BIGINT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.custom_badges (
  key TEXT PRIMARY KEY,
  symbol TEXT NOT NULL,
  color TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.gifs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  url TEXT NOT NULL,
  description TEXT DEFAULT '',
  added_by TEXT NOT NULL REFERENCES public.profiles(username) ON UPDATE CASCADE,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.app_config (
  key TEXT PRIMARY KEY,
  value JSONB NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ------------------------------------------------------------------------------
-- 14. Performance Indexes for Rapid Paged Loading & Lookups
-- ------------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_messages_server_channel_ts ON public.messages(server_id, channel_id, created_ts DESC);
CREATE INDEX IF NOT EXISTS idx_messages_channel_ts ON public.messages(channel_id, created_ts DESC);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON public.messages(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_dms_key_ts ON public.dms(channel_key, created_ts DESC);
CREATE INDEX IF NOT EXISTS idx_server_members_username ON public.server_members(username);
CREATE INDEX IF NOT EXISTS idx_server_members_server ON public.server_members(server_id);
CREATE INDEX IF NOT EXISTS idx_server_roles_server ON public.server_roles(server_id);
CREATE INDEX IF NOT EXISTS idx_server_bans_server ON public.server_bans(server_id);
CREATE INDEX IF NOT EXISTS idx_channels_server ON public.channels(server_id);
CREATE INDEX IF NOT EXISTS idx_profiles_username ON public.profiles(username);

-- ------------------------------------------------------------------------------
-- 15. Server Security Functions for RLS
-- ------------------------------------------------------------------------------

-- Check if user is server owner
CREATE OR REPLACE FUNCTION public.is_server_owner(sid TEXT, uname TEXT DEFAULT public.current_username())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.servers WHERE id = sid AND owner = uname
  );
$$;

-- Check if user is banned from a server
CREATE OR REPLACE FUNCTION public.is_server_banned(sid TEXT, uname TEXT DEFAULT public.current_username())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.server_bans WHERE server_id = sid AND username = uname
  );
$$;

-- Check if user is a member of a server
CREATE OR REPLACE FUNCTION public.is_server_member(sid TEXT, uname TEXT DEFAULT public.current_username())
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.server_members WHERE server_id = sid AND username = uname
  );
$$;

-- Check role-based server permission (manage_channels, manage_messages, kick_members, ban_members, mention_everyone)
CREATE OR REPLACE FUNCTION public.has_server_perm(sid TEXT, perm TEXT, uname TEXT DEFAULT public.current_username())
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_owner TEXT;
  v_has BOOLEAN := false;
BEGIN
  -- Admins always allowed
  IF public.is_admin() THEN
    RETURN true;
  END IF;

  -- Owner always allowed
  SELECT owner INTO v_owner FROM public.servers WHERE id = sid;
  IF v_owner = uname THEN
    RETURN true;
  END IF;

  -- Check if user has an assigned role with the permission
  IF perm = 'manage_channels' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.server_members sm
      JOIN public.server_roles sr ON sr.id = ANY(sm.roles)
      WHERE sm.server_id = sid AND sm.username = uname AND sr.manage_channels = true
    ) INTO v_has;
  ELSIF perm = 'manage_messages' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.server_members sm
      JOIN public.server_roles sr ON sr.id = ANY(sm.roles)
      WHERE sm.server_id = sid AND sm.username = uname AND sr.manage_messages = true
    ) INTO v_has;
  ELSIF perm = 'kick_members' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.server_members sm
      JOIN public.server_roles sr ON sr.id = ANY(sm.roles)
      WHERE sm.server_id = sid AND sm.username = uname AND sr.kick_members = true
    ) INTO v_has;
  ELSIF perm = 'ban_members' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.server_members sm
      JOIN public.server_roles sr ON sr.id = ANY(sm.roles)
      WHERE sm.server_id = sid AND sm.username = uname AND sr.ban_members = true
    ) INTO v_has;
  ELSIF perm = 'mention_everyone' THEN
    SELECT EXISTS (
      SELECT 1 FROM public.server_members sm
      JOIN public.server_roles sr ON sr.id = ANY(sm.roles)
      WHERE sm.server_id = sid AND sm.username = uname AND sr.mention_everyone = true
    ) INTO v_has;
  END IF;

  RETURN COALESCE(v_has, false);
END;
$$;

-- Check channel view permission
CREATE OR REPLACE FUNCTION public.can_view_channel(sid TEXT, cid TEXT, uname TEXT DEFAULT public.current_username())
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_roles TEXT[];
BEGIN
  IF public.is_admin() OR public.is_server_owner(sid, uname) THEN
    RETURN true;
  END IF;

  IF NOT public.is_server_member(sid, uname) THEN
    RETURN false;
  END IF;

  SELECT roles INTO v_roles FROM public.server_members WHERE server_id = sid AND username = uname;
  
  -- If denied by any assigned role override
  IF EXISTS (
    SELECT 1 FROM public.server_roles r
    WHERE r.server_id = sid AND (r.id = ANY(v_roles) OR LOWER(r.name) = 'member')
      AND (r.ch_overrides -> cid ->> 'v')::int = 0
  ) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

-- Check channel send/type permission
CREATE OR REPLACE FUNCTION public.can_send_in_channel(sid TEXT, cid TEXT, uname TEXT DEFAULT public.current_username())
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
AS $$
DECLARE
  v_locked BOOLEAN;
  v_roles TEXT[];
BEGIN
  IF public.is_admin() OR public.is_server_owner(sid, uname) THEN
    RETURN true;
  END IF;

  IF NOT public.is_server_member(sid, uname) OR public.is_server_banned(sid, uname) THEN
    RETURN false;
  END IF;

  SELECT is_locked INTO v_locked FROM public.channels WHERE server_id = sid AND id = cid;
  IF v_locked AND NOT public.has_server_perm(sid, 'manage_channels', uname) THEN
    RETURN false;
  END IF;

  SELECT roles INTO v_roles FROM public.server_members WHERE server_id = sid AND username = uname;

  -- If denied by any role override
  IF EXISTS (
    SELECT 1 FROM public.server_roles r
    WHERE r.server_id = sid AND (r.id = ANY(v_roles) OR LOWER(r.name) = 'member')
      AND (r.ch_overrides -> cid ->> 's')::int = 0
  ) THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

-- Check blocking relationship between two users
CREATE OR REPLACE FUNCTION public.is_user_blocked(u1 TEXT, u2 TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles WHERE (username = u1 AND u2 = ANY(blocked)) OR (username = u2 AND u1 = ANY(blocked))
  );
$$;

-- ------------------------------------------------------------------------------
-- 16. Enable Row Level Security (RLS) on all tables
-- ------------------------------------------------------------------------------
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.servers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.server_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.server_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.server_bans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.server_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.server_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_warnings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.custom_badges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gifs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- ------------------------------------------------------------------------------
-- 17. Row Level Security Policies
-- ------------------------------------------------------------------------------

-- PROFILES
DROP POLICY IF EXISTS "Profiles are readable by everyone" ON public.profiles;
CREATE POLICY "Profiles are readable by everyone"
  ON public.profiles FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Users can insert their own profile" ON public.profiles;
CREATE POLICY "Users can insert their own profile"
  ON public.profiles FOR INSERT
  WITH CHECK (username = public.current_username() OR public.is_admin());

DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Users can update their own profile"
  ON public.profiles FOR UPDATE
  USING (username = public.current_username() OR public.is_admin())
  WITH CHECK (
    -- Non-admins cannot alter is_banned or is_admin
    (public.is_admin()) OR
    (username = public.current_username() AND is_banned = (SELECT is_banned FROM public.profiles WHERE username = public.current_username()) AND is_admin = false)
  );

-- SERVERS
DROP POLICY IF EXISTS "Servers readable by members and community" ON public.servers;
CREATE POLICY "Servers readable by members and community"
  ON public.servers FOR SELECT
  USING (is_community = true OR public.is_server_member(id) OR public.is_admin());

DROP POLICY IF EXISTS "Authenticated users can create servers" ON public.servers;
CREATE POLICY "Authenticated users can create servers"
  ON public.servers FOR INSERT
  WITH CHECK (owner = public.current_username() AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE username = public.current_username() AND is_banned = true));

DROP POLICY IF EXISTS "Server owner and managers can update servers" ON public.servers;
CREATE POLICY "Server owner and managers can update servers"
  ON public.servers FOR UPDATE
  USING (owner = public.current_username() OR public.is_admin() OR public.has_server_perm(id, 'manage_channels'));

DROP POLICY IF EXISTS "Only owner and admin can delete server" ON public.servers;
CREATE POLICY "Only owner and admin can delete server"
  ON public.servers FOR DELETE
  USING ((owner = public.current_username() AND id != 'main') OR public.is_admin());

-- SERVER ROLES
DROP POLICY IF EXISTS "Server roles readable by members" ON public.server_roles;
CREATE POLICY "Server roles readable by members"
  ON public.server_roles FOR SELECT
  USING (public.is_server_member(server_id) OR public.is_admin());

DROP POLICY IF EXISTS "Server roles modifiable by managers" ON public.server_roles;
CREATE POLICY "Server roles modifiable by managers"
  ON public.server_roles FOR ALL
  USING (public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'manage_channels'));

-- SERVER MEMBERS
DROP POLICY IF EXISTS "Members readable by server members" ON public.server_members;
CREATE POLICY "Members readable by server members"
  ON public.server_members FOR SELECT
  USING (public.is_server_member(server_id) OR public.is_admin());

DROP POLICY IF EXISTS "Users can join if not banned" ON public.server_members;
CREATE POLICY "Users can join if not banned"
  ON public.server_members FOR INSERT
  WITH CHECK (username = public.current_username() AND NOT public.is_server_banned(server_id, public.current_username()));

DROP POLICY IF EXISTS "Owners and admins can update member roles" ON public.server_members;
CREATE POLICY "Owners and admins can update member roles"
  ON public.server_members FOR UPDATE
  USING (public.is_server_owner(server_id) OR public.is_admin());

DROP POLICY IF EXISTS "Users can leave or be kicked by moderators" ON public.server_members;
CREATE POLICY "Users can leave or be kicked by moderators"
  ON public.server_members FOR DELETE
  USING (
    username = public.current_username() OR
    public.is_server_owner(server_id) OR
    public.is_admin() OR
    (public.has_server_perm(server_id, 'kick_members') AND NOT public.is_server_owner(server_id, username))
  );

-- SERVER BANS
DROP POLICY IF EXISTS "Server bans readable by moderators" ON public.server_bans;
CREATE POLICY "Server bans readable by moderators"
  ON public.server_bans FOR SELECT
  USING (public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'ban_members'));

DROP POLICY IF EXISTS "Moderators can insert server bans" ON public.server_bans;
CREATE POLICY "Moderators can insert server bans"
  ON public.server_bans FOR INSERT
  WITH CHECK (
    (public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'ban_members'))
    AND NOT public.is_server_owner(server_id, username)
  );

DROP POLICY IF EXISTS "Moderators can delete server bans" ON public.server_bans;
CREATE POLICY "Moderators can delete server bans"
  ON public.server_bans FOR DELETE
  USING (public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'ban_members'));

-- SERVER INVITES
DROP POLICY IF EXISTS "Server invites viewable by members or invitees" ON public.server_invites;
CREATE POLICY "Server invites viewable by members or invitees"
  ON public.server_invites FOR SELECT
  USING (true);

DROP POLICY IF EXISTS "Server members can create invites" ON public.server_invites;
CREATE POLICY "Server members can create invites"
  ON public.server_invites FOR INSERT
  WITH CHECK (public.is_server_member(server_id) AND created_by = public.current_username());

DROP POLICY IF EXISTS "Invite creators and managers can delete invites" ON public.server_invites;
CREATE POLICY "Invite creators and managers can delete invites"
  ON public.server_invites FOR DELETE
  USING (created_by = public.current_username() OR public.is_server_owner(server_id) OR public.is_admin());

-- SERVER AUDIT LOG
DROP POLICY IF EXISTS "Audit log readable by managers" ON public.server_audit_log;
CREATE POLICY "Audit log readable by managers"
  ON public.server_audit_log FOR SELECT
  USING (public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'manage_channels'));

DROP POLICY IF EXISTS "Audit log insertable by server members" ON public.server_audit_log;
CREATE POLICY "Audit log insertable by server members"
  ON public.server_audit_log FOR INSERT
  WITH CHECK (public.is_server_member(server_id) AND actor = public.current_username());

-- CHANNELS
DROP POLICY IF EXISTS "Channels viewable by allowed members" ON public.channels;
CREATE POLICY "Channels viewable by allowed members"
  ON public.channels FOR SELECT
  USING (public.can_view_channel(server_id, id));

DROP POLICY IF EXISTS "Channels manageable by managers" ON public.channels;
CREATE POLICY "Channels manageable by managers"
  ON public.channels FOR ALL
  USING (public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'manage_channels'));

-- MESSAGES
DROP POLICY IF EXISTS "Messages viewable by channel viewers" ON public.messages;
CREATE POLICY "Messages viewable by channel viewers"
  ON public.messages FOR SELECT
  USING (public.can_view_channel(server_id, channel_id));

DROP POLICY IF EXISTS "Messages insertable by channel typers" ON public.messages;
CREATE POLICY "Messages insertable by channel typers"
  ON public.messages FOR INSERT
  WITH CHECK (
    username = public.current_username() AND
    public.can_send_in_channel(server_id, channel_id) AND
    -- Mentions permission validation
    (everyone_ping = false OR public.is_server_owner(server_id) OR public.is_admin() OR public.has_server_perm(server_id, 'mention_everyone'))
  );

DROP POLICY IF EXISTS "Messages updatable by author or managers" ON public.messages;
CREATE POLICY "Messages updatable by author or managers"
  ON public.messages FOR UPDATE
  USING (
    username = public.current_username() OR
    public.is_server_owner(server_id) OR
    public.is_admin() OR
    public.has_server_perm(server_id, 'manage_messages') OR
    public.is_server_member(server_id) -- allow member reaction updates
  );

DROP POLICY IF EXISTS "Messages deletable by author or managers" ON public.messages;
CREATE POLICY "Messages deletable by author or managers"
  ON public.messages FOR DELETE
  USING (
    username = public.current_username() OR
    public.is_server_owner(server_id) OR
    public.is_admin() OR
    public.has_server_perm(server_id, 'manage_messages')
  );

-- DIRECT MESSAGES (DMs & Groups)
DROP POLICY IF EXISTS "DMs viewable by participants" ON public.dms;
CREATE POLICY "DMs viewable by participants"
  ON public.dms FOR SELECT
  USING (
    public.current_username() = ANY(string_to_array(channel_key, '|')) OR
    (channel_key LIKE 'g%' AND EXISTS (SELECT 1 FROM public.groups WHERE id = channel_key AND public.current_username() = ANY(members))) OR
    public.is_admin()
  );

DROP POLICY IF EXISTS "DMs insertable by unblocked participants" ON public.dms;
CREATE POLICY "DMs insertable by unblocked participants"
  ON public.dms FOR INSERT
  WITH CHECK (
    sender = public.current_username() AND
    (
      -- Standard 1-on-1 DM: verify not blocked
      (
        public.current_username() = ANY(string_to_array(channel_key, '|')) AND
        NOT public.is_user_blocked(
          (string_to_array(channel_key, '|'))[1],
          (string_to_array(channel_key, '|'))[2]
        )
      ) OR
      -- Group DM: verify membership
      (
        channel_key LIKE 'g%' AND
        EXISTS (SELECT 1 FROM public.groups WHERE id = channel_key AND public.current_username() = ANY(members))
      )
    )
  );

DROP POLICY IF EXISTS "DMs updatable by sender or group members" ON public.dms;
CREATE POLICY "DMs updatable by sender or group members"
  ON public.dms FOR UPDATE
  USING (
    sender = public.current_username() OR
    public.current_username() = ANY(string_to_array(channel_key, '|')) OR
    (channel_key LIKE 'g%' AND EXISTS (SELECT 1 FROM public.groups WHERE id = channel_key AND public.current_username() = ANY(members)))
  );

DROP POLICY IF EXISTS "DMs deletable by sender" ON public.dms;
CREATE POLICY "DMs deletable by sender"
  ON public.dms FOR DELETE
  USING (sender = public.current_username() OR public.is_admin());

-- GROUPS
DROP POLICY IF EXISTS "Groups viewable by members" ON public.groups;
CREATE POLICY "Groups viewable by members"
  ON public.groups FOR SELECT
  USING (public.current_username() = ANY(members) OR public.is_admin());

DROP POLICY IF EXISTS "Groups insertable by authenticated users" ON public.groups;
CREATE POLICY "Groups insertable by authenticated users"
  ON public.groups FOR INSERT
  WITH CHECK (owner = public.current_username() AND public.current_username() = ANY(members));

DROP POLICY IF EXISTS "Groups updatable by members" ON public.groups;
CREATE POLICY "Groups updatable by members"
  ON public.groups FOR UPDATE
  USING (public.current_username() = ANY(members) OR public.is_admin());

DROP POLICY IF EXISTS "Groups deletable by owner or admin" ON public.groups;
CREATE POLICY "Groups deletable by owner or admin"
  ON public.groups FOR DELETE
  USING (owner = public.current_username() OR public.is_admin());

-- REPORTS
DROP POLICY IF EXISTS "Reports readable by admins" ON public.reports;
CREATE POLICY "Reports readable by admins"
  ON public.reports FOR SELECT
  USING (public.is_admin());

DROP POLICY IF EXISTS "Reports creatable by authenticated users" ON public.reports;
CREATE POLICY "Reports creatable by authenticated users"
  ON public.reports FOR INSERT
  WITH CHECK (reported_by = public.current_username());

DROP POLICY IF EXISTS "Reports dismissable by admins" ON public.reports;
CREATE POLICY "Reports dismissable by admins"
  ON public.reports FOR DELETE
  USING (public.is_admin());

-- USER WARNINGS
DROP POLICY IF EXISTS "Warnings viewable by recipient and admins" ON public.user_warnings;
CREATE POLICY "Warnings viewable by recipient and admins"
  ON public.user_warnings FOR SELECT
  USING (username = public.current_username() OR public.is_admin());

DROP POLICY IF EXISTS "Warnings manageable by admins" ON public.user_warnings;
CREATE POLICY "Warnings manageable by admins"
  ON public.user_warnings FOR ALL
  USING (public.is_admin());

-- CUSTOM BADGES & GIFS
DROP POLICY IF EXISTS "Badges readable by all" ON public.custom_badges;
CREATE POLICY "Badges readable by all" ON public.custom_badges FOR SELECT USING (true);
DROP POLICY IF EXISTS "Badges manageable by admins" ON public.custom_badges;
CREATE POLICY "Badges manageable by admins" ON public.custom_badges FOR ALL USING (public.is_admin());

DROP POLICY IF EXISTS "GIFs readable by all" ON public.gifs;
CREATE POLICY "GIFs readable by all" ON public.gifs FOR SELECT USING (true);
DROP POLICY IF EXISTS "GIFs insertable by authenticated users" ON public.gifs;
CREATE POLICY "GIFs insertable by authenticated users" ON public.gifs FOR INSERT WITH CHECK (added_by = public.current_username());
DROP POLICY IF EXISTS "GIFs deletable by author or admins" ON public.gifs;
CREATE POLICY "GIFs deletable by author or admins" ON public.gifs FOR DELETE USING (added_by = public.current_username() OR public.is_admin());

-- APP CONFIG (e.g. Update Log)
DROP POLICY IF EXISTS "Config readable by all" ON public.app_config;
CREATE POLICY "Config readable by all" ON public.app_config FOR SELECT USING (true);
DROP POLICY IF EXISTS "Config modifiable by admins" ON public.app_config;
CREATE POLICY "Config modifiable by admins" ON public.app_config FOR ALL USING (public.is_admin());

-- ------------------------------------------------------------------------------
-- 18. Supabase Realtime Setup
-- ------------------------------------------------------------------------------
-- Add key tables to Supabase Realtime replication publication
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.dms;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.channels;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
    BEGIN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.server_members;
    EXCEPTION WHEN duplicate_object THEN NULL;
    END;
  END IF;
END $$;

-- ------------------------------------------------------------------------------
-- 19. Supabase Storage Buckets & Policies
-- ------------------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES 
  ('avatars', 'avatars', true),
  ('banners', 'banners', true),
  ('messages', 'messages', true),
  ('emojis', 'emojis', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Storage RLS: Public Read for all media
DROP POLICY IF EXISTS "Public can view avatars" ON storage.objects;
CREATE POLICY "Public can view avatars" ON storage.objects FOR SELECT USING (bucket_id IN ('avatars','banners','messages','emojis'));

-- Storage RLS: Authenticated users can upload files
DROP POLICY IF EXISTS "Authenticated users can upload media" ON storage.objects;
CREATE POLICY "Authenticated users can upload media" ON storage.objects FOR INSERT
WITH CHECK (
  auth.role() = 'authenticated' AND
  bucket_id IN ('avatars','banners','messages','emojis')
);

-- Storage RLS: Users can update or delete their uploaded files
DROP POLICY IF EXISTS "Users can update own storage objects" ON storage.objects;
CREATE POLICY "Users can update own storage objects" ON storage.objects FOR UPDATE
USING (auth.uid() = owner);

DROP POLICY IF EXISTS "Users can delete own storage objects" ON storage.objects;
CREATE POLICY "Users can delete own storage objects" ON storage.objects FOR DELETE
USING (auth.uid() = owner OR public.is_admin());
