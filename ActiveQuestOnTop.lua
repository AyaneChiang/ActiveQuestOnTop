local addonName = ...

-- ---------------------------------------------------------------------------
-- ActiveQuestOnTop（魔獸世界：永恆 Forever）
-- 讓「最後操作的任務」永遠排在任務追蹤列表最上方。
--
-- 以下三種操作都會把該任務設為「置頂任務」：
--   1. 點任務標題（在任務日誌中選取）
--   2. 點任務前的圖示（設為專注）
--   3. 加入追蹤（手動追蹤，或接任務時自動追蹤）
--
-- 做法：在永恆中，重新加入追蹤的任務會被放到追蹤清單最前面，
-- 所以把置頂任務「移除追蹤 → 再加回追蹤」即可置頂。
-- 移除追蹤會讓遊戲取消該任務的專注，所以加回後要把專注設回去。
-- ---------------------------------------------------------------------------

local defaults = {
    enabled = true,
    debug = false,
}

-- 重排後這段時間內，若專注被遊戲改掉就設回去（秒）
local RESTORE_WINDOW = 0.5

local db
local topQuestID             -- 置頂任務
local pending = false        -- 已排程下一次更新（同一個 frame 內的多個事件只處理一次）
local busy = false           -- 正在重排，忽略過程中同步觸發的事件
local expectSuper, expectUntil   -- 重排後應維持的專注任務與期限

local function Debug(...)
    if db and db.debug then
        print("|cff33ff99AQOT|r", ...)
    end
end

local function GetWatchIndex(questID)
    for i = 1, C_QuestLog.GetNumQuestWatches() do
        if C_QuestLog.GetQuestIDForQuestWatchIndex(i) == questID then
            return i
        end
    end
    return nil
end

local function MoveTopQuestToTop()
    pending = false
    if not db.enabled or not topQuestID then return end

    local questID = topQuestID
    local index = GetWatchIndex(questID)
    if not index then
        -- 置頂任務已取消追蹤或已完成
        Debug("top quest no longer watched:", questID)
        topQuestID = nil
        return
    end
    if index == 1 then return end

    local wasSuper = C_SuperTrack.GetSuperTrackedQuestID() == questID
    if wasSuper then
        expectSuper, expectUntil = questID, GetTime() + RESTORE_WINDOW
    end

    busy = true
    local ok, err = pcall(function()
        -- 盡量保留原本的追蹤類型（自動／手動）
        local watchType = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID)
        C_QuestLog.RemoveQuestWatch(questID)
        if watchType == nil or not pcall(C_QuestLog.AddQuestWatch, questID, watchType) then
            C_QuestLog.AddQuestWatch(questID)
        end
        if wasSuper and C_SuperTrack.GetSuperTrackedQuestID() ~= questID then
            C_SuperTrack.SetSuperTrackedQuestID(questID)
        end
    end)
    busy = false

    if not ok then
        geterrorhandler()(err)
        return
    end
    Debug("moved to top:", questID, wasSuper and "(focus restored)" or "")
end

local function Schedule()
    if pending or not db then return end
    pending = true
    C_Timer.After(0, MoveTopQuestToTop)
end

-- 把某個任務設為置頂任務（必須正在追蹤中）
local function SetTopQuest(questID, reason)
    if busy or not questID or questID <= 0 then return end
    if not GetWatchIndex(questID) then return end
    if topQuestID ~= questID then
        Debug("top quest =", questID, "(" .. reason .. ")")
        topQuestID = questID
    end
    Schedule()
end

-- ---------------------------------------------------------------------------
-- 事件
-- ---------------------------------------------------------------------------

local function OnSuperTrackingChanged()
    if busy then return end
    local questID = C_SuperTrack.GetSuperTrackedQuestID() or 0

    -- 剛重排完：專注若被遊戲取消或換掉，設回原本的任務
    if expectSuper then
        if GetTime() <= expectUntil and GetWatchIndex(expectSuper) then
            if questID ~= expectSuper then
                Debug("restoring focus:", expectSuper)
                C_SuperTrack.SetSuperTrackedQuestID(expectSuper)
            end
            return
        end
        expectSuper, expectUntil = nil, nil
    end

    SetTopQuest(questID, "focus")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        ActiveQuestOnTopDB = ActiveQuestOnTopDB or {}
        db = ActiveQuestOnTopDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end

        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
        self:RegisterEvent("SUPER_TRACKING_CHANGED")

        -- 點任務標題（在任務日誌中選取任務）
        if C_QuestLog.SetSelectedQuest then
            hooksecurefunc(C_QuestLog, "SetSelectedQuest", function(questID)
                SetTopQuest(questID, "selected")
            end)
        end
        -- 依距離排序後，重新把置頂任務放回最上方
        if C_QuestLog.SortQuestWatches then
            hooksecurefunc(C_QuestLog, "SortQuestWatches", Schedule)
        end

        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "SUPER_TRACKING_CHANGED" then
        OnSuperTrackingChanged()

    elseif event == "QUEST_WATCH_LIST_CHANGED" then
        -- arg1 = questID, arg2 = 是否為加入追蹤
        if arg1 and arg2 then
            SetTopQuest(arg1, "watched")
        else
            Schedule()
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- 登入／重載後還沒有置頂任務時，先用目前的專注任務
        if not topQuestID then
            SetTopQuest(C_SuperTrack.GetSuperTrackedQuestID(), "login")
        end
    end
end)

-- ---------------------------------------------------------------------------
-- 指令：/aqot [on|off|toggle|debug]
-- ---------------------------------------------------------------------------

SLASH_ACTIVEQUESTONTOP1 = "/aqot"
SlashCmdList.ACTIVEQUESTONTOP = function(msg)
    if not db then return end
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "on" then
        db.enabled = true
    elseif msg == "off" then
        db.enabled = false
    elseif msg == "debug" then
        db.debug = not db.debug
        print("|cff33ff99AQOT|r debug:", db.debug and "ON" or "OFF")
        return
    elseif msg == "" or msg == "toggle" then
        db.enabled = not db.enabled
    else
        print("|cff33ff99AQOT|r 用法：/aqot [on|off|toggle|debug]")
        return
    end
    print("|cff33ff99AQOT|r", db.enabled and "已啟用" or "已停用")
    if db.enabled then Schedule() end
end
