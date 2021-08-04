local event = require("__flib__.event")
local table = require("__flib__.table")

local flib_dictionary = {}

local inner_separator = "⤬"
local separator = "⤬⤬⤬"
local max_depth = 15

local language_finished_event = event.generate_id()

local function kv(key, value)
  return key..inner_separator..value..separator
end

-- TODO: If we're storing the dictionaries in `global` ourselves, do we really need the Dictionary object?

local Dictionary = {}

function Dictionary:add(key, value)
  local to_add = {"", key, inner_separator, value, separator}

  local ref = self.ref
  local i = self.i + 1
  if i < 20 then
    ref[i] = to_add
    self.i = i
  else
    local r_i = self.r_i + 1
    if r_i <= max_depth then
      local new_level = {"", to_add}
      ref[i] = new_level
      self.ref = new_level
      self.i = 1
      self.r_i = r_i
    else
      local s_i = self.s_i + 1
      self.s_i = s_i
      local new_set = {""}
      self.ref = new_set
      self.strings[s_i] = new_set
      self.i = 1
      self.r_i = 1
    end
  end
end

--- Initialize the module's script data table.
-- Must be called at the beginning of `on_init` and during `on_configuration_changed` to reset all ongoing translations.
function flib_dictionary.init()
  if not global.__flib then
    global.__flib = {}
  end
  global.__flib.dictionary = {
    in_process = {},
    players = {},
    raw = {},
    translated = {}
  }
end

--- Create a new dictionary.
function flib_dictionary.new(name, keep_untranslated, initial_contents)
  if global.__flib.dictionary.raw[name] then
    error("Dictionary with the name `"..name.."` already exists.")
  end

  local initial_string = {""}
  local self = setmetatable(
    {
      -- Indices
      i = 1,
      r_i = 1,
      s_i = 1,
      -- Internal
      -- `ref` can't exist until after this table is initially created
      ref = initial_string,
      strings = {initial_string},
      -- Settings
      keep_untranslated = keep_untranslated,
      -- Meta
      name = name,
    },
    {__index = Dictionary}
  )

  for key, value in pairs(initial_contents or {}) do
    self:add(key, value)
  end

  global.__flib.dictionary.raw[name] = self

  return self
end

-- Add the player to the table and request the translation for their language code
function flib_dictionary.translate(player)
  local player_table = global.__flib.dictionary.players[player.index]
  if player_table then
    error("Player `"..player.name.."` ["..player.index.."] is already translating!")
  end

  global.__flib.dictionary.players[player.index] = {
    state = "get_language",
    player = player,
  }

  player.request_translation({"", "FLIB_LOCALE_IDENTIFIER", separator, {"locale-identifier"}})
end

function flib_dictionary.on_tick(event_data)
  local script_data = global.__flib.dictionary
  for player_index, player_table in pairs(script_data.players) do
    if player_table.status == "translating" then
      local i = player_table.i + 1
      local string = script_data.raw[player_table.dictionary].strings[i]
      if string then
        player_table.player.request_translation{
          "",
          kv("FLIB_DICTIONARY_NAME", player_table.dictionary),
          kv("FLIB_DICTIONARY_LANGUAGE", player_table.language),
          kv("FLIB_DICTIONARY_STRING_INDEX", i),
          string,
        }
        player_table.i = i
      else
        local next_dictionary = next(script_data.raw, player_table.dictionary)
        if next_dictionary then
          player_table.dictionary = next_dictionary
          player_table.i = 1
        else
          -- TODO: Handle edge case with missing translations when saving/loading a singleplayer game
          player_table.status = "finishing"
        end
      end
    end
  end
end

local dictionary_match_string = kv("^FLIB_DICTIONARY_NAME", "(.-)")
  ..kv("FLIB_DICTIONARY_LANGUAGE", "(.-)")
  ..kv("FLIB_DICTIONARY_STRING_INDEX", "(%d-)")
  .."(.*)$"

function flib_dictionary.handle_translation(event_data)
  if not event_data.translated then return end
  if string.find(event_data.result, "^FLIB_DICTIONARY_NAME") then
    local _, _, dict_name, dict_lang, string_index, translation = string.find(
      event_data.result,
      dictionary_match_string
    )

    if dict_name and dict_lang and string_index and translation then
      string_index = tonumber(string_index)
      local language_dictionaries = global.__flib.dictionary.in_process[dict_lang]
      -- In some cases, this can fire before on_configuration_changed
      if not language_dictionaries then return end
      local dictionary = language_dictionaries[dict_name]
      if not dictionary then return end
      local dict_data = global.__flib.dictionary.raw[dict_name]

      for str in string.gmatch(translation, "(.-)"..separator) do
        local _, _, key, value = string.find(str, "^(.-)"..inner_separator.."(.-)$")
        if key then
          -- If `keep_untranslated` is true, then use the key as the value if it failed
          local failed = string.find(value, "Unknown key:")
          if failed and dict_data.keep_untranslated then
            value = key
          elseif failed then
            value = nil
          end
          if value then
            dictionary[key] = value
          end
        end
      end
    end
  elseif string.find(event_data.result, "^FLIB_LOCALE_IDENTIFIER") then
    local _, _, language = string.find(event_data.result, "^FLIB_LOCALE_IDENTIFIER"..separator.."(.*)$")
    if language then
      local script_data = global.__flib.dictionary
      local player_table = script_data.players[event_data.player_index]
      if not player_table then return end

      player_table.language = language

      -- Check if this language is already translated or being translated
      local dictionaries = script_data.translated[language]
      if dictionaries then
        script_data.players[event_data.player_index] = nil
        event.raise(
          language_finished_event,
          {dictionaries = dictionaries, language = language, players = {e.player_index}}
        )
        return
      end
      local in_process = script_data.in_process[language]
      if in_process then
        table.insert(in_process.players, event_data.player_index)
        player_table.status = "waiting"
        return
      end

      -- Start translating this language
      player_table.status = "translating"
      player_table.dictionary = next(script_data.raw)
      player_table.i = 1

      script_data.in_process[language] = table.map(script_data.raw, function(_) return {} end)
    end
  end
end

flib_dictionary.language_finished_event = language_finished_event

return flib_dictionary