local _ = require("gettext")
local logger = require("logger")
local Device = require("device")
local ffiutil = require("ffi/util")
local PluginShare = require("pluginshare")
local ReaderUI = require("apps/reader/readerui")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screensaver = require("ui/screensaver")
local InfoMessage = require("ui/widget/infomessage")
local Screen = Device.screen
local T = ffiutil.template

local pluginSettings = require("plugin/settings")
local screensaverUtil = require("plugin/util/screensaverutil")
local screenshoterUtil = require("plugin/util/screenshoterutil")
local uiManagerUtil = require("plugin/util/uimanagerutil")
local NotesFrame = require("plugin/ui/lockscreen/notesframe")
local LockScreenFrame = require("plugin/ui/lockscreen/lockscreenframe")

local overlay
local notes

local function relayout(refreshmode)
    overlay:relayout(nil)
    if Screensaver.screensaver_widget then
        if Screensaver.screensaver_widget.update then
            -- KOReader up to 2025.10
            Screensaver.screensaver_widget:update()
        else
            Screensaver.screensaver_widget:init()
        end
    end
    UIManager:setDirty("all", refreshmode)
end

local function onSetRotationMode(_, mode)
    if not overlay then return end
    local old_mode = Screen:getRotationMode()
    if mode ~= nil and mode ~= old_mode then
        logger.dbg("ScreenLockPin: update rotation from " .. old_mode .. " to " .. mode)
        Screen:setRotationMode(mode)
        relayout("full")
    end
end

local function onScreenResize()
    if not overlay then return end
    logger.dbg("ScreenLockPin: handle screen resize")
    relayout("full")
end

local function formatAttempts()
    local attempts_by_length = pluginSettings.readPersistentCache("attempts_by_length") or {}
    local str = ""
    for len, attempts in pairs(attempts_by_length) do
        if str ~= "" then str = str .. "\n" end
        local line = "  " .. T(_("Length %1: %2 attempts"), len, attempts)
        str = str .. line
    end
    return str
end

local function teardownScreensaverOrLockscreen(keep_overlay)
    logger.dbg("ScreenLockPin: screensaver / lockscreen teardown")
    screensaverUtil.unfreezeScreensaverAbi()
    -- decide upon refresh type depending on if we unlock to reader UI
    local hasReaderUi = uiManagerUtil.findTopMostWidget(function(widget)
        return getmetatable(widget).__index == ReaderUI
    end) ~= nil
    if keep_overlay then
        -- Keep the lock screen on top while the UI below is swapped; the
        -- caller closes it once the target UI is ready, so the reader page
        -- never becomes visible in between.
        logger.dbg("ScreenLockPin: deferring overlay close")
        screensaverUtil.totalCleanup()
    elseif hasReaderUi then
        logger.dbg("ScreenLockPin: Reader detected; full refresh")
        screensaverUtil.totalCleanup()
        if overlay ~= nil then UIManager:close(overlay) end
        UIManager:setDirty("all", "full")
    else
        logger.dbg("ScreenLockPin: No reader detected; partial refresh should suffice")
        screensaverUtil.totalCleanup("flashui")
        if overlay ~= nil then
            UIManager:close(overlay, "flashui", overlay:getRefreshRegion())
        else
            UIManager:setDirty("all", "flashui")
        end
    end
    screenshoterUtil.unfreezeScreenshoterAbi()
    if keep_overlay then return end
    if overlay ~= nil then
        overlay:free()
        overlay = nil
    end
end

local function closeOverlay(refreshtype)
    if overlay == nil then return end
    UIManager:close(overlay, refreshtype)
    overlay:free()
    overlay = nil
end

--- Close the lock screen only once the reader is gone. Used when exiting
--- KOReader: the exit handler closes the reader asynchronously, and tearing
--- the lock screen down before that would briefly reveal the book page.
--- The lock screen's backdrop is kept until the very end as well, otherwise
--- the book becomes visible around the small PIN panel while exiting.
local function closeOverlayAfterReaderClosed(attempt)
    attempt = (attempt or 0) + 1
    if ReaderUI.instance ~= nil and attempt <= 50 then
        UIManager:scheduleIn(0.1, closeOverlayAfterReaderClosed, attempt)
        return
    end
    -- No refresh type: the Kindle UI repaints as soon as KOReader exits.
    teardownScreensaverOrLockscreen()
end

local function completeUnlock(destination, keep_overlay)
    if destination == "kindle_home" then
        logger.dbg("ScreenLockPin: exit KOReader after unlock")
        UIManager:broadcastEvent(Event:new("Exit"))
        if keep_overlay then
            closeOverlayAfterReaderClosed()
        end
        return
    end
    if destination == "koreader_home" and ReaderUI.instance then
        logger.dbg("ScreenLockPin: close book and open file manager home after unlock")
        local FileManager = require("apps/filemanager/filemanager")
        ReaderUI.instance:onHome()
        -- ReaderUI:onHome() only closes the book and reopens the file browser
        -- in the book's folder. Jump to the HOME folder instead.
        if FileManager.instance then
            local home_dir = G_reader_settings:readSetting("home_dir") or Device.home_dir
            if home_dir then
                FileManager.instance.file_chooser:changeToPath(home_dir)
            end
        end
    end
    if keep_overlay then
        -- Drop the lock screen and its backdrop, then reveal the target UI
        -- with a single full refresh.
        teardownScreensaverOrLockscreen(true)
        closeOverlay("full")
    end
    PluginShare.plugin_updater_v1.ping()
end

local function unlockScreen(cause, destination)
    if not overlay then return false end
    logger.dbg("ScreenLockPin: close lock screen (" .. cause .. ")")
    local throttled_times = pluginSettings.readPersistentCache("throttled_times") or 0
    -- When switching to another UI, keep the lock screen up until that UI is
    -- ready, otherwise the reader page becomes visible in between.
    local keep_overlay = (destination == "koreader_home" or destination == "kindle_home")
        and ReaderUI.instance ~= nil
        and throttled_times < 2
    local function continueAfterUnlock()
        UIManager:nextTick(function()
            completeUnlock(destination, keep_overlay)
        end)
    end
    if not keep_overlay then
        teardownScreensaverOrLockscreen()
    end
    if throttled_times >= 2 then
        UIManager:show(InfoMessage:new{
            text = T(_("Caution!\nHigh amount of failed PIN inputs detected.\n%1"), formatAttempts()),
            icon = "notice-warning",
            dismiss_callback = continueAfterUnlock,
        })
        pluginSettings.putPersistentCache("throttled_times", 0)
        pluginSettings.putPersistentCache("attempts_by_length", nil)
    else
        continueAfterUnlock()
    end
    return true
end

local function onSuspend()
    if notes then
        UIManager:close(notes)
        notes = nil
    end
    if not overlay then return end
    Device.screen_saver_lock = false
    overlay:setVisible(false)
    UIManager:setDirty("all", "full", overlay:getRefreshRegion())
end

local function reuseShowOverlay()
    logger.dbg("ScreenLockPin: clear & show lock")
    overlay:clearInput()
    overlay:setVisible(true)
    UIManager:setDirty(overlay, "flashui", overlay:getRefreshRegion())
end

local function onResume()
    if not overlay then return end
    if not pluginSettings.getEnabled() then
        unlockScreen("plugin_disabled")
        return
    end
    Device.screen_saver_lock = true
    reuseShowOverlay()
end

local function showNotesOverlay()
    if notes or not overlay then return end
    local text = pluginSettings.getNoteSettings().text or _("No note configured.")
    local scale = pluginSettings.getUiSettings().scale / 100
    notes = NotesFrame:new {
        text = text,
        region = overlay._content_region,
        scale = scale,
        on_close = function()
            UIManager:close(notes, "ui", notes.region)
            notes = nil
        end
    }
    UIManager:show(notes, "ui", notes.region)
end

--- In case of translucent image wallpapers, we need to drop the
--- `covers_fullscreen` flag of the screensaver widget in order to re-draw
--- content below on re-suspend as our overlay panel region must be fully
--- re-drawn.
local function ditherScreensaverFixup()
    if not Screensaver:modeIsImage() then return end
    if G_reader_settings:readSetting("screensaver_img_background") ~= "none" then return end
    Screensaver.screensaver_widget.covers_fullscreen = false
end

local function showOrClearLockScreen(cause)
    if cause == "resume" and overlay then
        logger.dbg("ScreenLockPin: ignoring duplicate resume trigger")
        -- ignore duplicate resume (triggered by plugin:onResume), it's already
        -- been handled by overlay:onResume
        return
    end
    logger.dbg("ScreenLockPin: show lock screen (" .. cause .. ")")
    if overlay then return reuseShowOverlay() end
    logger.dbg("ScreenLockPin: create lock screen")
    screensaverUtil.freezeScreensaverAbi()
    if pluginSettings.getPreventScreenshots() then
        screenshoterUtil.freezeScreenshoterAbi()
    end
    ditherScreensaverFixup()
    overlay = LockScreenFrame:new {
        -- UIManager performance tweaks
        modal = true,
        disable_double_tap = true,
        -- UIManager hook (called on ui root elements): handle rotation if not locked to orientation
        onSetRotationMode = onSetRotationMode,
        -- UIManager hook (called on ui root elements)
        onScreenResize = onScreenResize,
        -- UIManager hook (called on ui root elements)
        onSuspend = onSuspend,
        -- UIManager hook (called on ui root elements)
        onResume = onResume,
        -- LockScreenFrame
        on_unlock = function (destination) unlockScreen("valid_pin", destination) end,
        on_notes_overlay = showNotesOverlay,
    }
    UIManager:show(overlay, "flashui", overlay:getRefreshRegion())
end

return {
    showOrClearLockScreen = showOrClearLockScreen,
    unlockScreen = unlockScreen,
    skipLock = teardownScreensaverOrLockscreen,
    isActive = function () return overlay ~= nil end,
}
