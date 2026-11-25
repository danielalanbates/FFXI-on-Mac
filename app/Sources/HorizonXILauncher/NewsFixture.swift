/// A trimmed copy of `GET https://api.horizonxi.com/api/v1/news` as captured on 2026-10-15
/// (10 of its 30 posts, in the feed's order; two long patch-note bodies cut at a list end), for
/// `--selftest-news`. The text is HorizonXI's, unedited, mention tokens and all.
enum NewsFixture {
    static let horizonXI = #"""
[
 {
  "slug": "2026-10-09_server-notices_1558124900110172271",
  "title": "Server is up, enjoy the weekend",
  "date": "2026-10-09T14:32:04.747Z",
  "author": "Aerec",
  "excerpt": "",
  "html": "",
  "readingTime": "1 min read",
  "printDate": "October 9, 2026",
  "printReadingTime": "1 min read",
  "category": "server-notices",
  "categoryLabel": "Server Notice"
 },
 {
  "slug": "2026-10-09_patch-notes_1558118587439521824",
  "title": "Patch Notes for October 9, 2026",
  "date": "2026-10-09T14:06:59.689Z",
  "author": "Aerec",
  "excerpt": "Battlefields An issue where the orbs in \"Pulling the Plug\" would sometimes chase players should be resolved. The Light Elemental in Central Temenos 2F is done having an identity…",
  "html": "<h3>Battlefields</h3>\n<ul>\n<li>An issue where the orbs in \"Pulling the Plug\" would sometimes chase players should be resolved.</li>\n<li>The Light Elemental in Central Temenos 2F is done having an identity crisis and now accepts its a Light Elemental.</li>\n</ul>\n<h3>Mobs</h3>\n<ul>\n<li>Cherry Saplings should now stop spawning once Cemetery Cherry spawns.</li>\n<li>The Mycoskulker and Deforester camps in Aydeewa Subterrane have had their respawn times reduced slightly.</li>\n</ul>\n<h3>Combat</h3>\n<ul>\n<li>An issue that caused spells to occasionally show as 0 damage in combat logs has been corrected.</li>\n</ul>\n<h3>Quests</h3>\n<ul>\n<li>You should now be able to take the free boat ride from Mhaura to Selbina during the quest \"His Name is Valgeir\"</li>\n</ul>\n<h3>Items</h3>\n<ul>\n<li>Snakeeye and Snakeeye +1 now have their proper additional and latent effects.</li>\n<li>Aero Mufflers should now properly apply their enchantment.</li>\n<li>Blizzard Gloves should now properly apply their enchantment.</li>\n<li>Fire Bracers should now properly apply their enchantment.</li>\n<li>Stone Bangles should now properly apply their enchantment.</li>\n<li>Thunder Mittens should now properly apply their enchantment.</li>\n<li>Water Mitts should now properly apply their enchantment.</li>\n</ul>\n",
  "readingTime": "1 min read",
  "printDate": "October 9, 2026",
  "printReadingTime": "1 min read",
  "category": "patch-notes",
  "categoryLabel": "Patch Notes"
 },
 {
  "slug": "2026-10-09_server-notices_1557967530059104339",
  "title": "@everyoneApologies for the late notice - We will be doing maintenance at the normal time tomorrow ()",
  "date": "2026-10-09T04:06:44.803Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "",
  "html": "",
  "readingTime": "1 min read",
  "printDate": "October 9, 2026",
  "printReadingTime": "1 min read",
  "category": "server-notices",
  "categoryLabel": "Server Notice"
 },
 {
  "slug": "2026-10-05_patch-notes_1556595449471959071",
  "title": "Patch Notes for October 5, 2026",
  "date": "2026-10-05T09:14:35.299Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "Battlefields Players should now be able to do shady deals with Ropchop to leave Ghelsba Outpost battlefields early.",
  "html": "<h3>Battlefields</h3>\n<ul>\n<li>Players should now be able to do shady deals with Ropchop to leave Ghelsba Outpost battlefields early.</li>\n</ul>\n<h3>Combat</h3>\n<ul>\n<li>Players that have Bane removed from them now properly have their movement speed restored.</li>\n<li>An issue where pet experience with a group of 3 was not calculated properly has been resolved.</li>\n<li>Shatter Camps have been given an exception to the under-level penalty up to 20.</li>\n</ul>\n<h3>Monsters</h3>\n<ul>\n<li>A stray Fomor Bard in Wajaom Woodlands found their way back to solid ground.</li>\n<li>Cerberus, Khimaira, and Hydra now have Souleater Shield.</li>\n</ul>\n<h3>Items</h3>\n<ul>\n<li>Bibiki Seashell now properly awards the correct strength of Aquan Killer.</li>\n<li>Senior Gold Musketeer's Scythe now properly provides ACC +7 to citizens of Bastok.</li>\n<li>Beast Trousers +1 now have the proper Killer Effect strength.</li>\n</ul>\n<h3>NPCs</h3>\n<ul>\n<li>Zebada now uses the same clock as everyone else in Vana'diel.</li>\n<li>Moritz and friends now understand Zephyr Fan timers.<ul>\n<li>NOTE: Players will need to talk to Zebada on next interaction to correct their old timer.</li>\n</ul>\n</li>\n</ul>\n",
  "readingTime": "2 min read",
  "printDate": "October 5, 2026",
  "printReadingTime": "2 min read",
  "category": "patch-notes",
  "categoryLabel": "Patch Notes"
 },
 {
  "slug": "2026-10-02_patch-notes_1555590181783076975",
  "title": "Many of the era+ TP burn camps were gaining experience at rates that exceeded what we had intended. As such, we have…",
  "date": "2026-10-02T14:40:00.805Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "The following provides a list of changes that were made to merit camps: Gigas in Uleguerand Range have had their level range adjusted. The number of Gigas in Uleguerand Range has…",
  "html": "<ul>\n<li>The following provides a list of changes that were made to merit camps:<ul>\n<li>Gigas in Uleguerand Range have had their level range adjusted.</li>\n<li>The number of Gigas in Uleguerand Range has been adjusted.</li>\n<li>Wajaom Woodpecker in Wajaom Woodlands have had their level range adjusted.</li>\n<li>The number of Wajaom Woodpecker in Wajaom Woodlands has been adjusted.</li>\n<li>Deforester in Aydeewa Subterrane have had their level range adjusted.</li>\n<li>Mycoskulker in Aydeewa Subterrane have had their level range adjusted.</li>\n<li>The Deforester and Mycoskulker merit camps have had their spawns diversified.</li>\n<li>Scoriaceous Eruca in Mount Zhayolm have had their level range adjusted.</li>\n<li>Wamoura Prince in Mount Zhayolm have had their level range adjusted.</li>\n<li>The Scoriaceous Eruca and Wamoura Price merit camps have had their spawns diversified.</li>\n<li>The number and location of the Ebony Puddings in Mount Zhayolm has been adjusted.</li>\n<li>Dweomershells in Arrapago Reef have had their level range adjusted.</li>\n<li>Nirgali in Arrapago Reef have had their level range adjusted.</li>\n<li>The number of Orichalcumshell in Mount Zhayolm has been adjusted.</li>\n</ul>\n</li>\n</ul>\n",
  "readingTime": "3 min read",
  "printDate": "October 2, 2026",
  "printReadingTime": "3 min read",
  "category": "patch-notes",
  "categoryLabel": "Patch Notes"
 },
 {
  "slug": "2026-10-02_announcements_1555456960600739841",
  "title": "Horizon Wiki Follow Up",
  "date": "2026-10-02T05:50:38.400Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "I have just been notified by the community wiki team that the site should now be back up and running. Make sure to give a shoutout to the maintainers if you see them around!",
  "html": "<p>I have just been notified by the community wiki team that the site should now be back up and running.  Make sure to give a shoutout to the maintainers if you see them around!</p>\n",
  "readingTime": "1 min read",
  "printDate": "October 2, 2026",
  "printReadingTime": "1 min read",
  "category": "announcements",
  "categoryLabel": "Announcement"
 },
 {
  "slug": "2026-10-02_server-notices_1555417205418627134",
  "title": "Reminder: Maintenance will be at normal time tomorrow ()",
  "date": "2026-10-02T03:12:40.026Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "",
  "html": "",
  "readingTime": "1 min read",
  "printDate": "October 2, 2026",
  "printReadingTime": "1 min read",
  "category": "server-notices",
  "categoryLabel": "Server Notice"
 },
 {
  "slug": "2026-09-28_known-issues_1554271240351645807",
  "title": "We are aware that the wiki is currently down at the moment and working to resolve it as soon as possible",
  "date": "2026-09-28T23:19:00.663Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "",
  "html": "",
  "readingTime": "1 min read",
  "printDate": "September 28, 2026",
  "printReadingTime": "1 min read",
  "category": "known-issues",
  "categoryLabel": "Known Issue"
 },
 {
  "slug": "2026-09-27_server-notices_1553632481503354941",
  "title": "Will be doing a short maintenance to address some lingering issues",
  "date": "2026-09-27T05:00:48.686Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "Please plan accordingly and make sure you do not start things like dynamis unless you can finish before: .",
  "html": "<p>Please plan accordingly and make sure you do not start things like dynamis unless you can finish before: .</p>\n",
  "readingTime": "1 min read",
  "printDate": "September 27, 2026",
  "printReadingTime": "1 min read",
  "category": "server-notices",
  "categoryLabel": "Server Notice"
 },
 {
  "slug": "2026-09-23_server-notices_1552162716410712096",
  "title": "@everyoneWill be doing a quick maintenance to apply an important fix",
  "date": "2026-09-23T03:40:29.381Z",
  "author": "1nt3rc3pt0r",
  "excerpt": "Please make sure you dont start any events that you wont be able to finish before this time.",
  "html": "<p>Please make sure you dont start any events that you wont be able to finish before this time.</p>\n",
  "readingTime": "1 min read",
  "printDate": "September 23, 2026",
  "printReadingTime": "1 min read",
  "category": "server-notices",
  "categoryLabel": "Server Notice"
 }
]
"""#
}
