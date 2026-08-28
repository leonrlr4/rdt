"""Tests for bin/reddit-fetch.

Run with the system interpreter, the same one the plugin uses:

    /usr/bin/python3 -m unittest discover -s tests -v

stdlib unittest, not pytest: the plugin's whole premise is that it runs on a
stock Omarchy box with no extra packages, and the tests should hold to that too.

Nothing here touches the network or the real cookie store. The parts that do
are thin wrappers over curl/sqlite; the logic worth testing is the auth
selection, normalization and unread bookkeeping around them.
"""

import base64
import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from unittest import mock

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, os.pardir, "bin", "reddit-fetch")
_spec = importlib.util.spec_from_loader(
    "reddit_fetch", importlib.machinery.SourceFileLoader("reddit_fetch", _SCRIPT))
rf = importlib.util.module_from_spec(_spec)
sys.modules["reddit_fetch"] = rf
_spec.loader.exec_module(rf)


def make_token(exp):
    """A token_v2-shaped JWT. Only the payload's `exp` is ever read, and it is
    read without signature verification, so a stub signature is enough."""
    payload = base64.urlsafe_b64encode(
        json.dumps({"exp": exp, "iat": exp - 86400}).encode()).rstrip(b"=")
    return "header." + payload.decode() + ".signature"


class TestPadding(unittest.TestCase):
    def test_strips_valid_pkcs7(self):
        self.assertEqual(rf.unpad(b"hello" + b"\x03\x03\x03"), b"hello")

    def test_leaves_unpadded_data_alone(self):
        # A trailing byte that is not consistent padding must survive.
        self.assertEqual(rf.unpad(b"hello\x03\x04"), b"hello\x03\x04")

    def test_empty(self):
        self.assertEqual(rf.unpad(b""), b"")


class TestTokenExpiry(unittest.TestCase):
    def test_reads_exp(self):
        self.assertAlmostEqual(rf.token_expiry(make_token(1787926991)),
                               1787926991, places=0)

    def test_malformed_token_is_not_fatal(self):
        for bad in ("", "notajwt", "a.b", "a.!!!.c"):
            self.assertIsNone(rf.token_expiry(bad))
            self.assertFalse(rf.token_is_fresh(bad))

    def test_fresh_token(self):
        self.assertTrue(rf.token_is_fresh(make_token(time.time() + 3600)))

    def test_expired_token(self):
        self.assertFalse(rf.token_is_fresh(make_token(time.time() - 10)))

    def test_token_expiring_within_skew_counts_as_stale(self):
        # Otherwise a token can die mid-request and the 401 is indistinguishable
        # from being logged out.
        soon = time.time() + 60
        self.assertFalse(rf.token_is_fresh(make_token(soon), skew=300))


class TestAuthSelection(unittest.TestCase):
    def test_prefers_oauth_when_token_is_fresh(self):
        jar = {"token_v2": make_token(time.time() + 3600),
               "reddit_session": "sess"}
        url, headers = rf.build_request("/best?limit=5", jar)
        self.assertTrue(url.startswith("https://oauth.reddit.com/best"))
        self.assertIn("Authorization: Bearer " + jar["token_v2"], headers)

    def test_falls_back_to_cookie_when_token_is_stale(self):
        jar = {"token_v2": make_token(time.time() - 10),
               "reddit_session": "sess"}
        url, headers = rf.build_request("/best?limit=5", jar)
        self.assertEqual(url, "https://www.reddit.com/best.json?limit=5")
        self.assertTrue(any("Cookie: " in h for h in headers))

    def test_cookie_path_inserts_json_before_query(self):
        jar = {"reddit_session": "sess"}
        url, _ = rf.build_request("/r/linux/hot?limit=25&raw_json=1", jar)
        self.assertEqual(
            url, "https://www.reddit.com/r/linux/hot.json?limit=25&raw_json=1")

    def test_cookie_path_without_query(self):
        jar = {"reddit_session": "sess"}
        url, _ = rf.build_request("/best", jar)
        self.assertEqual(url, "https://www.reddit.com/best.json")

    def test_no_usable_auth_raises_auth_expired(self):
        with self.assertRaises(rf.FetchError) as ctx:
            rf.build_request("/best", {"token_v2": make_token(time.time() - 10)})
        self.assertEqual(ctx.exception.code, "auth_expired")


class TestFeedPath(unittest.TestCase):
    def test_home_aliases(self):
        for name in ("best", "home", "BEST", "", "  "):
            self.assertEqual(rf.feed_path(name), "/best")

    def test_subreddit_with_and_without_prefix(self):
        self.assertEqual(rf.feed_path("r/linux"), "/r/linux/hot")
        self.assertEqual(rf.feed_path("linux"), "/r/linux/hot")
        self.assertEqual(rf.feed_path("/r/linux/"), "/r/linux/hot")


class TestNormalization(unittest.TestCase):
    def listing(self, **overrides):
        post = {"id": "abc", "title": "Hello", "subreddit": "linux",
                "author": "someone", "score": 107, "num_comments": 308,
                "created_utc": 1787880075.0, "permalink": "/r/linux/comments/abc/x/",
                "url": "https://example.com", "thumbnail": "self",
                "selftext": "body", "stickied": False, "over_18": False}
        post.update(overrides)
        return {"data": {"children": [{"kind": "t3", "data": post}]}}

    def test_maps_the_fields_the_ui_needs(self):
        post = rf.normalize_listing(self.listing())[0]
        self.assertEqual(post["id"], "abc")
        self.assertEqual(post["score"], 107)
        self.assertEqual(post["comments"], 308)
        self.assertEqual(post["permalink"],
                         "https://www.reddit.com/r/linux/comments/abc/x/")

    def test_sentinel_thumbnails_become_empty(self):
        for sentinel in ("self", "default", "nsfw", "spoiler", "image", ""):
            post = rf.normalize_listing(self.listing(thumbnail=sentinel))[0]
            self.assertEqual(post["thumbnail"], "")

    def test_real_thumbnail_survives(self):
        post = rf.normalize_listing(
            self.listing(thumbnail="https://b.thumbs.redditmedia.com/x.jpg"))[0]
        self.assertEqual(post["thumbnail"],
                         "https://b.thumbs.redditmedia.com/x.jpg")

    def test_non_post_children_are_dropped(self):
        payload = {"data": {"children": [{"kind": "t1", "data": {"id": "c"}}]}}
        self.assertEqual(rf.normalize_listing(payload), [])

    def test_missing_fields_do_not_crash(self):
        payload = {"data": {"children": [{"kind": "t3", "data": {}}]}}
        post = rf.normalize_listing(payload)[0]
        self.assertEqual(post["title"], "")
        self.assertEqual(post["score"], 0)

    def test_selftext_is_capped(self):
        post = rf.normalize_listing(self.listing(selftext="x" * 5000))[0]
        self.assertEqual(len(post["selftext"]), 2000)

    def test_null_selftext(self):
        post = rf.normalize_listing(self.listing(selftext=None))[0]
        self.assertEqual(post["selftext"], "")


class TestSearch(unittest.TestCase):
    """Finding a subreddit you cannot already name."""

    def payload(self, *subs):
        return {"data": {"children": [{"data": d} for d in subs]}}

    def test_orders_by_subscribers(self):
        out = rf.normalize_search(self.payload(
            {"display_name": "small", "subscribers": 10},
            {"display_name": "big", "subscribers": 900},
            {"display_name": "mid", "subscribers": 100}))
        self.assertEqual([s["name"] for s in out], ["big", "mid", "small"])

    def test_user_profiles_are_dropped(self):
        # This endpoint returns profile pages as u_<name> subreddits, which
        # are not somewhere you would pin as a tab.
        out = rf.normalize_search(self.payload(
            {"display_name": "u_someone", "subreddit_type": "user"},
            {"display_name": "linux", "subreddit_type": "public"}))
        self.assertEqual([s["name"] for s in out], ["linux"])

    def test_nameless_entries_are_dropped(self):
        self.assertEqual(rf.normalize_search(self.payload({"subscribers": 5})), [])

    def test_description_is_collapsed_and_capped(self):
        out = rf.normalize_search(self.payload(
            {"display_name": "a", "public_description": "one\n\n  two   three"}))
        self.assertEqual(out[0]["description"], "one two three")
        long = rf.normalize_search(self.payload(
            {"display_name": "a", "public_description": "x" * 400}))
        self.assertEqual(len(long[0]["description"]), 200)

    def test_missing_fields_do_not_crash(self):
        out = rf.normalize_search(self.payload({"display_name": "a"}))
        self.assertEqual(out[0]["subscribers"], 0)
        self.assertEqual(out[0]["description"], "")
        self.assertFalse(out[0]["over18"])

    def test_nsfw_is_flagged_not_hidden(self):
        out = rf.normalize_search(self.payload(
            {"display_name": "a", "over18": True}))
        self.assertTrue(out[0]["over18"])

    def test_empty_payload(self):
        self.assertEqual(rf.normalize_search({}), [])

    def test_blank_query_makes_no_request(self):
        called = []
        patcher = mock.patch.object(
            rf, "curl", lambda *a, **k: called.append(1) or {})
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher2 = mock.patch.object(
            rf, "load_session", lambda browser=None: ("chromium", {}))
        patcher2.start()
        self.addCleanup(patcher2.stop)

        class A:
            browser = None
            query = "   "
            limit = 12

        self.assertEqual(rf.cmd_search(A())["subreddits"], [])
        self.assertEqual(called, [])


class TestLinkDomain(unittest.TestCase):
    """A subreddit can switch media off -- r/linux has -- and then Reddit
    returns no thumbnail, no preview and no post_hint for any of its posts.
    The domain is what is left to say where a row goes."""

    def test_link_post_keeps_its_domain(self):
        self.assertEqual(rf.link_domain({"domain": "example.com"}),
                         "example.com")

    def test_text_post_has_none(self):
        self.assertEqual(rf.link_domain({"is_self": True,
                                         "domain": "self.linux"}), "")

    def test_self_prefixed_domain_has_none(self):
        # Reddit writes self.<sub> even when is_self is missing.
        self.assertEqual(rf.link_domain({"domain": "self.linux"}), "")

    def test_missing_domain(self):
        self.assertEqual(rf.link_domain({}), "")

    def test_normalized_post_carries_it(self):
        post = rf.normalize_listing({"data": {"children": [{"kind": "t3", "data": {
            "id": "a", "domain": "gamingonlinux.com"}}]}})[0]
        self.assertEqual(post["domain"], "gamingonlinux.com")


class TestReadableText(unittest.TestCase):
    """Markdown survives; only what the renderer cannot use is removed."""

    def test_markdown_syntax_is_left_alone(self):
        # The panel renders Markdown natively, so stripping it would be
        # working against the renderer.
        for text in ("**bold** and *italic*",
                     "# Heading",
                     "> quoted",
                     "* one\n* two",
                     "`code`",
                     "[label](https://example.com/a)"):
            self.assertEqual(rf.readable_text(text), text)

    def test_bare_image_line_goes_with_its_newline(self):
        # Drawn as a picture instead. Removing the URL but leaving the blank
        # line would invent a paragraph break the author never wrote.
        text = "Look at this:\nhttps://i.redd.it/abc123.png\nNice, right?"
        # The two trailing spaces are the hard break that keeps the author's
        # line ending -- see TestHardBreaks.
        self.assertEqual(rf.readable_text(text), "Look at this:  \nNice, right?")

    def test_reddit_preview_url_goes(self):
        text = ("Body\n\nhttps://preview.redd.it/i7l0itfpk0mh1.png?"
                "width=3565&format=png&auto=webp&s=811751d73fdc7e142bcbd")
        self.assertEqual(rf.readable_text(text), "Body")

    def test_url_inside_a_sentence_is_kept(self):
        text = "I used https://example.com/a.png as the source"
        self.assertEqual(rf.readable_text(text), text)

    def test_long_bare_url_is_elided_to_its_host(self):
        out = rf.readable_text("see https://example.com/" + "x" * 60 + " now")
        self.assertEqual(out, "see example.com/… now")

    def test_long_url_inside_a_markdown_link_is_untouched(self):
        # It is invisible once rendered, and eliding it would break the link.
        link = "[label](https://example.com/" + "x" * 60 + ")"
        self.assertEqual(rf.readable_text(link), link)

    def test_non_breaking_spaces_become_spaces(self):
        self.assertEqual(rf.readable_text("a\u00a0b"), "a b")

    def test_runs_of_blank_lines_collapse(self):
        self.assertEqual(rf.readable_text("a\n\n\n\n\nb"), "a\n\nb")

    def test_none_and_empty(self):
        self.assertEqual(rf.readable_text(None), "")
        self.assertEqual(rf.readable_text(""), "")


class TestHardBreaks(unittest.TestCase):
    """Reddit breaks a line where the author pressed enter; CommonMark folds a
    lone newline into a space. Without this a multi-line comment renders as one
    run-on paragraph."""

    def test_consecutive_lines_get_a_hard_break(self):
        self.assertEqual(rf.readable_text("line one\nline two"),
                         "line one  \nline two")

    def test_paragraph_breaks_are_left_alone(self):
        self.assertEqual(rf.readable_text("a\n\nb"), "a\n\nb")

    def test_fenced_code_is_untouched(self):
        src = "```\ncode a\ncode b\n```"
        self.assertEqual(rf.readable_text(src), src)

    def test_indented_code_is_untouched(self):
        src = "    code a\n    code b"
        self.assertEqual(rf.readable_text(src), src)

    def test_list_items_break_on_their_own(self):
        for src in ("* one\n* two", "- one\n- two", "1. one\n2. two"):
            self.assertEqual(rf.readable_text(src), src)

    def test_headings_and_quotes_break_on_their_own(self):
        self.assertEqual(rf.readable_text("# Title\ntext"), "# Title\ntext")
        self.assertEqual(rf.readable_text("> a\n> b"), "> a\n> b")

    def test_a_line_already_ending_in_a_break_is_not_doubled(self):
        self.assertEqual(rf.readable_text("a  \nb"), "a  \nb")

    def test_last_line_gets_nothing(self):
        self.assertFalse(rf.readable_text("only one line").endswith("  "))


class TestMediaEmbeds(unittest.TestCase):
    """Reddit writes an inline GIF as ![gif](giphy|ID). Left in the text, a
    Markdown renderer draws a broken-image icon where the GIF should be."""

    def test_giphy_id_becomes_a_real_url(self):
        text, media = rf.extract_media("![gif](giphy|abc123)")
        self.assertEqual(text, "")
        self.assertEqual(media, [{
            "url": "https://media.giphy.com/media/abc123/200w.gif",
            "kind": "gif"}])

    def test_a_rendition_suffix_is_not_part_of_the_id(self):
        # Real ids arrive as giphy|<id>|downsized; carrying the suffix into the
        # URL is a 403.
        _, media = rf.extract_media("![gif](giphy|oImOwaZ34b8K70aQ6B|downsized)")
        self.assertEqual(media[0]["url"],
                         "https://media.giphy.com/media/oImOwaZ34b8K70aQ6B/200w.gif")

    def test_surrounding_text_survives(self):
        text, media = rf.extract_media("This is a trap\n\n![gif](giphy|xy)")
        self.assertEqual(text.strip(), "This is a trap")
        self.assertEqual(len(media), 1)

    def test_emotes_are_dropped_without_a_caption(self):
        # media_metadata answers "invalid" for these and the alt is always
        # the placeholder "img", which is not worth showing.
        text, media = rf.extract_media("![img](emote|t5_2th52|4358)")
        self.assertEqual(text, "")
        self.assertEqual(media, [])

    def test_a_real_caption_is_kept_when_nothing_is_drawable(self):
        text, media = rf.extract_media("![my diagram](emote|t5_x|1)")
        self.assertEqual(text, "my diagram")
        self.assertEqual(media, [])

    def test_media_metadata_resolves_a_hosted_upload(self):
        meta = {"k1": {"status": "valid", "e": "AnimatedImage",
                       "s": {"u": "https://i.redd.it/k1.gif"}}}
        _, media = rf.extract_media("![img](k1)", meta)
        self.assertEqual(media, [{"url": "https://i.redd.it/k1.gif",
                                  "kind": "gif"}])

    def test_invalid_media_metadata_draws_nothing(self):
        meta = {"k1": {"status": "invalid"}}
        text, media = rf.extract_media("![img](k1)", meta)
        self.assertEqual(media, [])
        self.assertEqual(text, "")

    def test_a_plain_url_target_is_drawable(self):
        _, media = rf.extract_media("![x](https://e.com/a.png)")
        self.assertEqual(media, [{"url": "https://e.com/a.png",
                                  "kind": "image"}])

    def test_duplicates_are_drawn_once(self):
        _, media = rf.extract_media("![gif](giphy|a) ![gif](giphy|a)")
        self.assertEqual(len(media), 1)

    def test_comment_carries_its_media(self):
        comment = rf.normalize_comment(
            {"data": {"body": "ha\n\n![gif](giphy|zz)", "author": "u"}})
        self.assertEqual(comment["body"], "ha")
        self.assertEqual(len(comment["media"]), 1)

    def test_post_selftext_carries_its_media(self):
        post = rf.normalize_listing({"data": {"children": [{"kind": "t3", "data": {
            "id": "a", "selftext": "look\n\n![gif](giphy|zz)"}}]}})[0]
        self.assertEqual(post["selftext"], "look")
        self.assertEqual(len(post["media"]), 1)

    def test_a_post_with_no_embeds_reports_an_empty_list(self):
        post = rf.normalize_listing({"data": {"children": [
            {"kind": "t3", "data": {"id": "a", "selftext": "plain"}}]}})[0]
        self.assertEqual(post["media"], [])


class TestPreviewImage(unittest.TestCase):
    """The post's own `url` is the full-size original; renditions exist for a
    reason and a bar panel should use one."""

    def post(self, widths):
        return {"preview": {"images": [{
            "source": {"url": "https://e/src.jpg", "width": 4000, "height": 3000},
            "resolutions": [{"url": "https://e/%d.jpg" % w, "width": w,
                             "height": w // 2} for w in widths]}]}}

    def test_picks_the_smallest_rendition_wide_enough(self):
        self.assertEqual(
            rf.preview_image(self.post([108, 216, 320, 640, 960, 1080]))["width"], 640)

    def test_falls_back_to_the_largest_when_all_are_too_small(self):
        self.assertEqual(rf.preview_image(self.post([108, 216, 320]))["width"], 320)

    def test_falls_back_to_source_when_there_are_no_renditions(self):
        self.assertEqual(rf.preview_image(self.post([]))["url"], "https://e/src.jpg")

    def test_unordered_resolutions_still_pick_correctly(self):
        self.assertEqual(
            rf.preview_image(self.post([1080, 108, 640, 320]))["width"], 640)

    def test_post_without_preview(self):
        self.assertIsNone(rf.preview_image({}))
        self.assertIsNone(rf.preview_image({"preview": {}}))
        self.assertIsNone(rf.preview_image({"preview": {"images": []}}))


class TestGallery(unittest.TestCase):
    """Gallery posts carry no `preview` at all -- their pictures live in
    gallery_data + media_metadata, which the listing endpoints strip."""

    def gallery(self, count=2, widths=(108, 320, 640, 1080), status="valid"):
        return {
            "is_gallery": True,
            "gallery_data": {"items": [{"media_id": "m%d" % i}
                                       for i in range(count)]},
            "media_metadata": {
                "m%d" % i: {"status": status, "e": "Image",
                            "s": {"u": "https://e/m%d-src.png" % i,
                                  "x": 4000, "y": 2000},
                            "p": [{"u": "https://e/m%d-%d.png" % (i, w),
                                   "x": w, "y": w // 2} for w in widths]}
                for i in range(count)},
        }

    def test_every_image_in_order(self):
        images = rf.gallery_images(self.gallery(3))
        self.assertEqual([i["url"] for i in images],
                         ["https://e/m0-640.png", "https://e/m1-640.png",
                          "https://e/m2-640.png"])

    def test_carries_dimensions_for_aspect_ratio(self):
        image = rf.gallery_images(self.gallery(1))[0]
        self.assertEqual((image["width"], image["height"]), (640, 320))

    def test_falls_back_to_source_without_renditions(self):
        image = rf.gallery_images(self.gallery(1, widths=()))[0]
        self.assertEqual(image["url"], "https://e/m0-src.png")

    def test_invalid_entries_are_skipped(self):
        self.assertEqual(rf.gallery_images(self.gallery(2, status="invalid")), [])

    def test_a_non_gallery_post_has_none(self):
        self.assertEqual(rf.gallery_images({}), [])

    def test_post_images_prefers_the_whole_gallery(self):
        self.assertEqual(len(rf.post_images(self.gallery(6))), 6)

    def test_post_images_falls_back_to_the_single_preview(self):
        plain = {"preview": {"images": [{
            "source": {"url": "https://e/s.jpg", "width": 900, "height": 600},
            "resolutions": [{"url": "https://e/640.jpg", "width": 640,
                             "height": 420}]}]}}
        self.assertEqual(rf.post_images(plain),
                         [{"url": "https://e/640.jpg", "width": 640,
                           "height": 420}])

    def test_a_post_with_neither_has_no_images(self):
        self.assertEqual(rf.post_images({}), [])

    def test_normalized_gallery_post(self):
        raw = dict(self.gallery(6))
        raw.update({"id": "a", "title": "t", "permalink": "/p/"})
        post = rf.normalize_listing({"data": {"children": [
            {"kind": "t3", "data": raw}]}})[0]
        self.assertEqual(len(post["images"]), 6)
        self.assertTrue(post["isGallery"])

    def test_video_posts_are_flagged(self):
        post = rf.normalize_listing({"data": {"children": [{"kind": "t3", "data": {
            "id": "a", "is_video": True}}]}})[0]
        self.assertTrue(post["isVideo"])
        self.assertFalse(post["isGallery"])


class TestOwnVote(unittest.TestCase):
    """`likes` exists only because the request is authenticated as you: None
    means no vote, not "no score"."""

    def test_post_vote_states(self):
        for raw, expected in ((True, True), (False, False), (None, None)):
            post = rf.normalize_listing({"data": {"children": [{"kind": "t3",
                "data": {"id": "a", "likes": raw}}]}})[0]
            self.assertIs(post["liked"], expected)

    def test_comment_vote_states(self):
        for raw, expected in ((True, True), (False, False), (None, None)):
            comment = rf.normalize_comment({"data": {"likes": raw}})
            self.assertIs(comment["liked"], expected)

    def test_saved_and_author_id_carry_through(self):
        post = rf.normalize_listing({"data": {"children": [{"kind": "t3", "data": {
            "id": "a", "saved": True, "author_fullname": "t2_zz"}}]}})[0]
        self.assertTrue(post["saved"])
        self.assertEqual(post["authorId"], "t2_zz")


class TestAvatars(unittest.TestCase):
    """Reddit puts no avatar on a comment, but resolves many accounts at once.
    One request per thread, not one per commenter."""

    def comments(self):
        return [{"authorId": "t2_a", "avatar": ""},
                {"authorId": "t2_b", "avatar": ""},
                {"authorId": "t2_a", "avatar": ""},
                {"authorId": "", "avatar": ""}]

    def patch_curl(self, result):
        calls = []

        def fake(url, headers, timeout=20):
            calls.append(url)
            if isinstance(result, Exception):
                raise result
            return result

        patcher = mock.patch.object(rf, "curl", fake)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher2 = mock.patch.object(
            rf, "build_request", lambda path, jar, now=None: (path, []))
        patcher2.start()
        self.addCleanup(patcher2.stop)
        return calls

    def test_one_request_for_the_whole_thread(self):
        calls = self.patch_curl({})
        rf.attach_avatars(self.comments(), {})
        self.assertEqual(len(calls), 1)

    def test_each_account_asked_for_once(self):
        calls = self.patch_curl({})
        rf.attach_avatars(self.comments(), {})
        self.assertIn("ids=t2_a,t2_b", calls[0])

    def test_avatars_land_on_every_matching_comment(self):
        self.patch_curl({"t2_a": {"profile_img": "https://e/a.png"},
                         "t2_b": {"profile_img": "https://e/b.png"}})
        comments = self.comments()
        rf.attach_avatars(comments, {})
        self.assertEqual([c["avatar"] for c in comments],
                         ["https://e/a.png", "https://e/b.png",
                          "https://e/a.png", ""])

    def test_html_escaped_urls_are_unescaped(self):
        # This endpoint escapes its URLs regardless of raw_json, and the &amp;
        # invalidates the signed query -- Reddit answers 403 for the image.
        self.patch_curl({"t2_a": {"profile_img":
            "https://e/a.png?width=256&amp;s=abc&amp;crop=1"}})
        comments = [{"authorId": "t2_a", "avatar": ""}]
        rf.attach_avatars(comments, {})
        self.assertEqual(comments[0]["avatar"],
                         "https://e/a.png?width=256&s=abc&crop=1")

    def test_a_failed_lookup_does_not_lose_the_thread(self):
        # An avatar is decoration; the comments matter.
        self.patch_curl(rf.FetchError("offline", "no"))
        comments = self.comments()
        rf.attach_avatars(comments, {})
        self.assertEqual([c["avatar"] for c in comments], ["", "", "", ""])

    def test_no_authors_makes_no_request(self):
        calls = self.patch_curl({})
        rf.attach_avatars([{"authorId": "", "avatar": ""}], {})
        self.assertEqual(calls, [])

    def test_the_post_author_is_included(self):
        calls = self.patch_curl({})
        rf.attach_avatars([], {}, {"authorId": "t2_op", "avatar": ""})
        self.assertIn("ids=t2_op", calls[0])


class TestComments(unittest.TestCase):
    def payload(self):
        def node(cid, body, replies=None):
            data = {"id": cid, "author": "u" + cid, "score": 5,
                    "created_utc": 1.0, "body": body}
            data["replies"] = ({"data": {"children": replies}} if replies else "")
            return {"kind": "t1", "data": data}

        return [
            {"data": {"children": [{"kind": "t3", "data": {"id": "p"}}]}},
            {"data": {"children": [
                node("a", "top", [node("b", "reply", [node("c", "deep")])]),
                node("d", "second"),
            ]}},
        ]

    def test_flattens_with_depth(self):
        out = rf.flatten_comments(self.payload(), max_depth=3)
        self.assertEqual([(c["id"], c["depth"]) for c in out],
                         [("a", 0), ("b", 1), ("c", 2), ("d", 0)])

    def test_max_depth_prunes(self):
        out = rf.flatten_comments(self.payload(), max_depth=1)
        self.assertEqual([c["id"] for c in out], ["a", "d"])

    def test_limit_is_respected(self):
        out = rf.flatten_comments(self.payload(), max_depth=3, limit=2)
        self.assertEqual(len(out), 2)

    def test_more_markers_are_skipped(self):
        payload = [{}, {"data": {"children": [{"kind": "more", "data": {}}]}}]
        self.assertEqual(rf.flatten_comments(payload), [])

    def test_malformed_payload_returns_empty(self):
        for bad in ([], [{}], {}, None, [{"data": {}}]):
            self.assertEqual(rf.flatten_comments(bad), [])


class TestSeenState(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "sub", "seen.json")

    def tearDown(self):
        self.dir.cleanup()

    def test_missing_file_means_nothing_seen(self):
        self.assertEqual(rf.load_seen(self.path), [])

    def test_corrupt_file_means_nothing_seen(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as fh:
            fh.write("{not json")
        self.assertEqual(rf.load_seen(self.path), [])

    def test_round_trip_preserves_order(self):
        # Order is what makes the cap mean "drop the oldest"; a set here would
        # make eviction arbitrary and resurrect posts you already read.
        rf.save_seen(self.path, ["a", "b", "c"])
        self.assertEqual(rf.load_seen(self.path), ["a", "b", "c"])

    def test_non_string_entries_are_ignored(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as fh:
            json.dump({"seen": ["a", 7, None, "b"]}, fh)
        self.assertEqual(rf.load_seen(self.path), ["a", "b"])

    def test_creates_parent_directory(self):
        rf.save_seen(self.path, ["a"])
        self.assertTrue(os.path.isfile(self.path))

    def test_cap_drops_the_oldest_not_an_arbitrary_one(self):
        ids = [str(i) for i in range(rf.SEEN_CAP + 250)]
        rf.save_seen(self.path, ids)
        kept = rf.load_seen(self.path)
        self.assertEqual(len(kept), rf.SEEN_CAP)
        self.assertEqual(kept, ids[-rf.SEEN_CAP:])
        self.assertNotIn("0", kept)
        self.assertIn(ids[-1], kept)

    def test_unread_excludes_seen(self):
        posts = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        self.assertEqual(rf.unread_ids(posts, {"b"}), ["a", "c"])

    def test_posts_without_ids_are_not_unread(self):
        self.assertEqual(rf.unread_ids([{"id": ""}], set()), [])

    def test_a_post_in_two_feeds_counts_once(self):
        # Subscribing to r/x puts its posts on /best too, so the same post
        # arrives twice in one poll. Counting rows inflates the badge.
        posts = [{"id": "a"}, {"id": "b"}, {"id": "a"}]
        self.assertEqual(rf.unread_ids(posts, set()), ["a", "b"])

    def test_order_is_first_appearance(self):
        posts = [{"id": "b"}, {"id": "a"}, {"id": "b"}]
        self.assertEqual(rf.unread_ids(posts, set()), ["b", "a"])


class TestMarkRead(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "seen.json")
        self.addCleanup(self.dir.cleanup)

    def run_mark(self, ids):
        class A:
            pass
        a = A()
        a.seen_file = self.path
        a.ids = ids
        return rf.cmd_mark_read(a)

    def test_appends_new_ids_in_order(self):
        self.run_mark("a,b")
        self.run_mark("c")
        self.assertEqual(rf.load_seen(self.path), ["a", "b", "c"])

    def test_remarking_does_not_move_an_id(self):
        # Re-reading an old post must not push a different old id off the cap.
        self.run_mark("a,b,c")
        self.run_mark("a")
        self.assertEqual(rf.load_seen(self.path), ["a", "b", "c"])

    def test_blank_and_whitespace_ids_are_skipped(self):
        self.run_mark("a, ,,b")
        self.assertEqual(rf.load_seen(self.path), ["a", "b"])


class TestFeedCommand(unittest.TestCase):
    """cmd_feed's partial-failure policy: one dead feed must not sink a poll,
    but every feed dying the same way is a session problem."""

    def setUp(self):
        self.jar = {"token_v2": make_token(time.time() + 3600)}
        # patch.object restores on cleanup; hand-rolled save/restore leaks a
        # stub into whichever test class happens to run next.
        patcher = mock.patch.object(
            rf, "load_session", lambda browser=None: ("chromium", self.jar))
        patcher.start()
        self.addCleanup(patcher.stop)

    def patch_fetch(self, responses):
        patcher = mock.patch.object(
            rf, "fetch_many", lambda reqs, timeout=20: responses)
        patcher.start()
        self.addCleanup(patcher.stop)

    def args(self, feeds):
        class A:
            pass
        a = A()
        a.browser = None
        a.feeds = feeds
        a.limit = 25
        a.seen_file = None
        return a

    def listing(self, post_id):
        return {"data": {"children": [
            {"kind": "t3", "data": {"id": post_id, "title": "t",
                                    "subreddit": "s", "permalink": "/p/"}}]}}

    def test_one_failing_feed_does_not_sink_the_others(self):
        self.patch_fetch({
            "best": self.listing("a"),
            "r/dead": rf.FetchError("http_error", "HTTP 404"),
        })
        out = rf.cmd_feed(self.args("best,r/dead"))
        self.assertTrue(out["ok"])
        by_feed = {f["feed"]: f for f in out["feeds"]}
        self.assertEqual(len(by_feed["best"]["posts"]), 1)
        self.assertEqual(by_feed["r/dead"]["error"], "http_error")

    def test_all_feeds_failing_surfaces_one_error(self):
        self.patch_fetch({
            "best": rf.FetchError("auth_expired", "no"),
            "r/linux": rf.FetchError("auth_expired", "no"),
        })
        with self.assertRaises(rf.FetchError) as ctx:
            rf.cmd_feed(self.args("best,r/linux"))
        self.assertEqual(ctx.exception.code, "auth_expired")

    def test_unread_counts_across_all_feeds(self):
        self.patch_fetch({"best": self.listing("a"),
                          "r/linux": self.listing("b")})
        out = rf.cmd_feed(self.args("best,r/linux"))
        self.assertEqual(out["unread"], 2)
        self.assertEqual(sorted(out["unreadIds"]), ["a", "b"])


class TestErrorSerialization(unittest.TestCase):
    """The QML side branches on `error`, so failures must always be a JSON
    object on stdout with a stable code -- never a traceback."""

    def test_failure_is_json_with_a_code(self):
        import io
        import contextlib
        def boom(browser=None):
            raise rf.FetchError("keyring_locked", "locked")

        patcher = mock.patch.object(rf, "load_session", boom)
        patcher.start()
        self.addCleanup(patcher.stop)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = rf.main(["feed", "--feeds", "best"])
        self.assertEqual(rc, 1)
        payload = json.loads(buf.getvalue())
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"], "keyring_locked")
        self.assertIn("message", payload)


if __name__ == "__main__":
    unittest.main()
