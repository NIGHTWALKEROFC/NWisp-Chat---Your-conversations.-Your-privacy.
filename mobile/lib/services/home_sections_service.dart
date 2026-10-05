import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which extra sections appear as tabs at the bottom of the home screen
/// (besides Chats, which is always there). Both default to ON and are
/// switched from Settings > Chats.
///
/// Stored on this phone only (nothing is synced) — like every other
/// display preference in the app. The [ValueNotifier]s let the home screen
/// and the chat list react the moment a switch is flipped in Settings, no
/// restart needed.
class HomeSectionsService {
  HomeSectionsService._();

  static const _kAnnouncements = 'home_section_announcements';
  static const _kCommunity = 'home_section_community';
  static const _kNearby = 'home_section_nearby';
  static const _kStoriesTab = 'home_section_stories_tab';
  static const _kStoriesOnHome = 'home_stories_on_home';

  /// ON: announcement-only groups live in their own "Announcements" tab and
  /// are kept OUT of the Chats list. OFF: they are mixed into Chats like any
  /// other group.
  static final ValueNotifier<bool> announcementsTab = ValueNotifier(true);

  /// ON: the "Community" tab is shown. OFF: it is hidden (joined communities
  /// still stay out of Chats — they are never mixed in).
  static final ValueNotifier<bool> communityTab = ValueNotifier(true);

  /// Feature: ON: the "Nearby" tab (chat with people close by, no internet)
  /// is shown. Switch it off in Settings > Chats if you don't need it.
  static final ValueNotifier<bool> nearbyTab = ValueNotifier(true);

  /// ON: the \"Stories\" tab is in the bottom bar.
  static final ValueNotifier<bool> storiesTab = ValueNotifier(true);

  /// ON: a stories row also sits at the top of the Chats screen. OFF by
  /// default — stories live in their own tab; turn this on in Settings > Chats.
  static final ValueNotifier<bool> storiesOnHome = ValueNotifier(false);

  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    announcementsTab.value = prefs.getBool(_kAnnouncements) ?? true;
    communityTab.value = prefs.getBool(_kCommunity) ?? true;
    nearbyTab.value = prefs.getBool(_kNearby) ?? true;
    storiesTab.value = prefs.getBool(_kStoriesTab) ?? true;
    storiesOnHome.value = prefs.getBool(_kStoriesOnHome) ?? false;
    _loaded = true;
  }

  static Future<void> setAnnouncementsTab(bool value) async {
    announcementsTab.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAnnouncements, value);
  }

  static Future<void> setNearbyTab(bool value) async {
    nearbyTab.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNearby, value);
  }

  static Future<void> setStoriesTab(bool value) async {
    storiesTab.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kStoriesTab, value);
  }

  static Future<void> setStoriesOnHome(bool value) async {
    storiesOnHome.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kStoriesOnHome, value);
  }

  static Future<void> setCommunityTab(bool value) async {
    communityTab.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCommunity, value);
  }
}
