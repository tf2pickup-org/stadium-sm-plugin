#include <sourcemod>
#include <sdktools>
#include <tf2>
#include <tf2_stocks>
#include <regex>
#undef REQUIRE_PLUGIN
#include <updater>

#pragma semicolon 1
#pragma newdecls required

#define UPDATE_URL "https://raw.githubusercontent.com/tf2pickup-org/teams-control/main/updatefile.txt"

public Plugin myinfo = 
{
    name = "[TF2] Teams Control", 
    author = "Forward Command Post, TF2Stadium (tf2pickup fork)", 
    description = "Allows automatic configuration of player whitelist, classes and teams.", 
    version = "1.0", 
    url = "github.com/tf2pickup-org"
};

ArrayList g_Whitelist;
ConVar g_EnableWhitelist;
StringMap g_Names;
StringMap g_Teams;
StringMap g_Classes;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion g_engineversion = GetEngineVersion();
    if (g_engineversion != Engine_TF2)
    {
        SetFailState("This plugin was made for use with Team Fortress 2 only.");
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    RegServerCmd("sm_game_player_add", Command_GamePlayerAdd, "Adds a player to a game.");
    RegServerCmd("sm_game_player_del", Command_GamePlayerRemove, "Removes a player from a game.");
    RegServerCmd("sm_game_player_delall", Command_GameReset, "Removes all players from game.");
    RegServerCmd("sm_game_player_list", Command_ListPlayers, "Lists all configured players.");
    
    g_EnableWhitelist = CreateConVar("sm_game_player_whitelist", "0", "Sets whether or not to auto-kick players not on the list.", _, true, 0.0, true, 1.0);
    g_EnableWhitelist.AddChangeHook(OnWhitelistToggled);

    g_Whitelist = new ArrayList(32);
    g_Names = new StringMap();
    g_Teams = new StringMap();
    g_Classes = new StringMap();
    
    HookEvent("player_changename", Event_NameChange, EventHookMode_Post);

    HookUserMessage(GetUserMessageId("SayText2"), UserMessage_SayText2, true);
    HookUserMessage(GetUserMessageId("Train"), UserMessage_Train, true);

    if (LibraryExists("updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }

    LoadTranslations("teamscontrol.phrases");

    ServerCommand("sm_game_player_add 76561198179807307 -class scout -team red -name holatest");
    ServerCommand("mp_tournament 1");
    ServerCommand("mp_tournament_restart");
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }
}

public void OnClientPostAdminCheck(int client)
{
    char steamID64[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamID64, sizeof(steamID64)))
    {
        ThrowError("Steam ID not retrieved");
    }
    
    if (g_Whitelist.FindString(steamID64) == -1)
    {
        if (g_EnableWhitelist.BoolValue)
        {
            KickClient(client, "%t", "not_authorized");
        }
    }
    else
    {
        char name[32];
        if (g_Names.GetString(steamID64, name, sizeof(name)))
        {
            SetClientName(client, name);
        }
        
        int team;
        TFClassType class;
        bool foundTeam = g_Teams.GetValue(steamID64, team);
        bool foundClass = g_Classes.GetValue(steamID64, class);

        if (foundTeam && foundClass)
        {
            DataPack pack = new DataPack();
            pack.WriteCell(client);
            pack.WriteCell(team);
            pack.WriteCell(class);
            RequestFrame(Frame_AssignTeamAndClass, pack);
        }
        else
        {
            if (foundTeam)
            {
                DataPack pack = new DataPack();
                pack.WriteCell(client);
                pack.WriteCell(team);
                RequestFrame(Frame_AssignTeam, pack);
            }

            if (foundClass)
            {
                DataPack pack = new DataPack();
                pack.WriteCell(client);
                pack.WriteCell(class);
                RequestFrame(Frame_AssignClass, pack);
            }
        }
    }
}

void Frame_AssignTeamAndClass(DataPack pack)
{
    pack.Reset();
    int client = pack.ReadCell();
    int team = pack.ReadCell();
    TFClassType class = view_as<TFClassType>(pack.ReadCell());
    ChangeClientTeam(client, team);

    pack = new DataPack();
    pack.WriteCell(client);
    pack.WriteCell(class);
    RequestFrame(Frame_AssignClass, pack);
}

void Frame_AssignTeam(DataPack pack)
{
    pack.Reset();
    int client = pack.ReadCell();
    int team = pack.ReadCell();
    delete pack;
    ChangeClientTeam(client, team);
}

void Frame_AssignClass(DataPack pack)
{
    pack.Reset();
    int client = pack.ReadCell();
    TFClassType class = view_as<TFClassType>(pack.ReadCell());
    delete pack;
    TF2_SetPlayerClass(client, class);
}

public Action Command_GameReset(int args)
{
    g_Whitelist.Clear();
    g_Names.Clear();
    g_Teams.Clear();
    g_Classes.Clear();
    
    if (g_EnableWhitelist.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                KickClient(i, "%t", "server_reset");
            }
        }
    }
    
    PrintToServer("[SM] The whitelist has been reset.");
    return Plugin_Handled;
}

public Action Command_GamePlayerAdd(int args)
{
    if (args == 0)
    {
        PrintToServer("[SM] Usage: sm_game_player_add <STEAMID64> [-team red|blu] [-class #class] [-name name]");
        return Plugin_Handled;
    }

    char steamID[32];
    GetCmdArg(1, steamID, sizeof(steamID));

    if (SimpleRegexMatch(steamID, "\\b\\d{17}\\b") == 0)
    {
        PrintToServer("[SM] Invalid STEAMID64 supplied.");
        return Plugin_Handled;
    }

    if (g_Whitelist.FindString(steamID) == -1)
    {
        g_Whitelist.PushString(steamID);
        PrintToServer("[SM] %s added successfully.", steamID);
    }
    else
    {
        PrintToServer("[SM] %s was already whitelisted.", steamID);
    }
    
    // Parse optional -arg val parameter options.
    char arg[32];
    char val[32];
    for (int i = 2; i + 1 <= args; i += 2)
    {
        GetCmdArg(i, arg, sizeof(arg));
        GetCmdArg(i + 1, val, sizeof(val));
        
        if (strcmp("-team", arg, false) == 0)
        {
            int id = TF2_GetTeam(val);
            if (id != -1)
            {
                g_Teams.SetValue(steamID, id, true);
                PrintToServer("[SM] %s assigned team %d.", steamID, id);
            }
        }
        else if (strcmp("-class", arg, false) == 0)
        {
            TFClassType id = TF2_GetClass(val);
            if (id != TFClass_Unknown)
            {
                g_Classes.SetValue(steamID, id, true);
                PrintToServer("[SM] %s assigned class %s.", steamID, val);
            }
            else
            {
                int idNum = StringToInt(val);
                if (idNum >= 1 && idNum <= 9)
                {
                    g_Classes.SetValue(steamID, idNum, true);
                    PrintToServer("[SM] %s assigned class %s.", steamID, val);
                }
            }
        }
        else if (strcmp("-name", arg, false) == 0)
        {
            g_Names.SetString(steamID, val, true);
            PrintToServer("[SM] %s assigned name %s.", steamID, val);
        }
    }

    return Plugin_Handled;
}

public Action Command_GamePlayerRemove(int args)
{
    char steamID[32];
    GetCmdArg(1, steamID, sizeof(steamID));
    
    if (g_Whitelist.FindString(steamID) != -1)
    {
        g_Whitelist.Erase(g_Whitelist.FindString(steamID));
        PrintToServer("[SM] %s was removed from the whitelist.", steamID);
    }
    else
    {
        PrintToServer("[SM] %s was not in the whitelist.");
    }

    g_Names.Remove(steamID);
    g_Teams.Remove(steamID);
    g_Classes.Remove(steamID);
    
    if (g_EnableWhitelist.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                char clientSteamID[32];
                if (GetClientAuthId(i, AuthId_SteamID64, clientSteamID, sizeof(clientSteamID)))
                {
                    if (StrEqual(steamID, clientSteamID))
                    {
                        KickClient(i, "%t", "removed");
                        PrintToServer("[SM] %s was found and removed from the server.", steamID);
                        return Plugin_Handled;
                    }
                }
            }
        }
    }

    return Plugin_Handled;
}

public Action Command_ListPlayers(int args)
{
    int n = g_Whitelist.Length;
    
    if (n == 0)
    {
        PrintToServer("[SM] The player list is empty.");
    }
    else 
    {
        char clientSteamID64[32];
        PrintToServer("Player list:");
        for (int i = 0; i < n; i++)
        {
            g_Whitelist.GetString(i, clientSteamID64, sizeof(clientSteamID64));
            PrintToServer("  - %d: %s", i, clientSteamID64);
        }
    }

    return Plugin_Handled;
}

public void Event_NameChange(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    
    char newName[32];
    event.GetString("newname", newName, sizeof(newName));
    
    char steamID[32];
    GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID));
    
    char playerName[32];
    if (g_Names.GetString(steamID, playerName, sizeof(playerName)))
    {
        if (!StrEqual(newName, playerName))
        {
            SetClientName(client, playerName);
        }
    }
}

public Action UserMessage_SayText2(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
    char buffer[512];
    
    if (!reliable)
    {
        return Plugin_Continue;
    }
    
    msg.ReadByte();
    msg.ReadByte();
    msg.ReadString(buffer, sizeof(buffer), false);
    
    if (StrContains(buffer, "#TF_Name_Change") != -1)
    {
        return Plugin_Handled;
    }
    
    return Plugin_Continue;
}

public Action UserMessage_Train(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init) 
{
    if (playersNum == 1 && IsClientConnected(players[0]) && !IsFakeClient(players[0]))
    {
        CreateTimer(0.0, KillMOTD, GetClientUserId(players[0]), TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Continue;
}

public Action KillMOTD(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client)
    {
        ShowVGUIPanel(client, "info", _, false);
    }
    return Plugin_Continue;
}

public void OnWhitelistToggled(ConVar convar, const char[] oldValue, const char[] newValue)
{
    switch (newValue[0])
    {
        case '0': if (oldValue[0] != '0') PrintToServer("[SM] Whitelist disabled.");
        case '1': if (oldValue[0] != '1') PrintToServer("[SM] Whitelist enabled.");
    }
}

int TF2_GetTeam(const char[] name)
{
    if (strcmp(name, "2") == 0)
    {
        return 2;
    }
    else if (strcmp(name, "3") == 0) {
        return 3;
    }
    else if (strcmp(name, "red") == 0) {
        return 2;
    }
    else if (strcmp(name, "blue") == 0) {
        return 3;
    }
    else if (strcmp(name, "blu") == 0) {
        return 3;
    }
    
    return -1;
}