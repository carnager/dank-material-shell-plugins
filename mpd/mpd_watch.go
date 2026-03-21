package main

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const clerkCacheTTL = 60 * time.Second

var (
	clerkAlbumCache          = map[string]clerkAlbumRef{}
	clerkAlbumCacheExpiresAt time.Time
	yearPattern              = regexp.MustCompile(`(\d{4})`)
)

type clerkAlbumRef struct {
	ID     string
	Rating string
}

type normalizedTrackData struct {
	TrackNumber string `json:"tracknumber"`
	Artist      string `json:"artist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	AlbumArtist string `json:"albumartist"`
	Date        string `json:"date"`
	Year        string `json:"year"`
	FileName    string `json:"filename"`
	Rating      string `json:"rating"`
	AlbumRating string `json:"albumrating"`
}

type albumTrack struct {
	TrackNumber string `json:"tracknumber"`
	Title       string `json:"title"`
}

type albumInfo struct {
	Title       string       `json:"title"`
	AlbumArtist string       `json:"albumartist"`
	Year        string       `json:"year"`
	AlbumRating string       `json:"albumrating"`
	ClerkID     string       `json:"clerk_id"`
	ArtPath     string       `json:"art_path"`
	TrackCount  int          `json:"track_count"`
	Tracks      []albumTrack `json:"tracks"`
	Files       []string     `json:"files"`
	CurrentIdx  int          `json:"current_index"`
}

type queueTrack struct {
	Pos         int    `json:"pos"`
	TrackNumber string `json:"tracknumber"`
	Artist      string `json:"artist"`
	AlbumArtist string `json:"albumartist"`
	Title       string `json:"title"`
	Album       string `json:"album"`
	AlbumKey    string `json:"album_key"`
	Current     bool   `json:"current"`
}

type queueInfo struct {
	CurrentPos int          `json:"current_pos"`
	Tracks     []queueTrack `json:"tracks"`
}

type artistAlbumInfo struct {
	AlbumKey    string `json:"album_key"`
	Title       string `json:"title"`
	Year        string `json:"year"`
	AlbumRating string `json:"albumrating"`
	TrackCount  int    `json:"track_count"`
}

type snapshotPayload struct {
	Type         string                       `json:"type"`
	Connected    bool                         `json:"connected"`
	State        string                       `json:"state"`
	Track        normalizedTrackData          `json:"track"`
	AlbumInfo    albumInfo                    `json:"album_info"`
	QueueInfo    queueInfo                    `json:"queue_info"`
	ArtistAlbums map[string][]artistAlbumInfo `json:"artist_albums"`
	AlbumDetails map[string]albumInfo         `json:"album_details"`
	ArtPath      string                       `json:"art_path"`
	Error        string                       `json:"error"`
}

type browserAlbumEntry struct {
	ID          string `json:"id"`
	Album       string `json:"album"`
	AlbumArtist string `json:"albumartist"`
	Date        string `json:"date"`
	Year        string `json:"year"`
	Rating      string `json:"rating"`
}

type albumBrowserPayload struct {
	Type   string              `json:"type"`
	Mode   string              `json:"mode"`
	Albums []browserAlbumEntry `json:"albums"`
	Error  string              `json:"error"`
}

type mpdClient struct {
	conn net.Conn
	r    *bufio.Reader
	w    *bufio.Writer
}

func emit(payload any) {
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(payload)
}

func extractYear(value string) string {
	match := yearPattern.FindStringSubmatch(value)
	if len(match) > 1 {
		return match[1]
	}
	return ""
}

func normalizeRatingValue(value string) string {
	text := strings.TrimSpace(value)
	if text == "" {
		return ""
	}

	var number float64
	if strings.Contains(text, "/") {
		parts := strings.SplitN(text, "/", 2)
		left, err1 := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
		right, err2 := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
		if err1 != nil || err2 != nil {
			return ""
		}
		number = left
		if right > 0 {
			number = left * 5.0 / right
		}
	} else {
		parsed, err := strconv.ParseFloat(text, 64)
		if err != nil {
			return ""
		}
		number = parsed
	}

	switch {
	case number > 10:
		number = number / 20.0
	case number > 5:
		number = number / 2.0
	}

	if number < 0 {
		number = 0
	}
	if number > 5 {
		number = 5
	}

	rounded := float64(int(number*2.0+0.5)) / 2.0
	formatted := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.1f", rounded), "0"), ".")
	return formatted
}

func normalizeClerkBaseURL(value string) string {
	return strings.TrimRight(strings.TrimSpace(value), "/")
}

func resolveClerkAPIBaseURL(baseURLArg string) string {
	normalized := normalizeClerkBaseURL(baseURLArg)
	if normalized != "" {
		return normalized
	}

	xdgConfigHome := os.Getenv("XDG_CONFIG_HOME")
	if xdgConfigHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		xdgConfigHome = filepath.Join(home, ".config")
	}

	configPath := filepath.Join(xdgConfigHome, "clerk", "clerk-api-rofi.conf")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return ""
	}

	inGeneral := false
	for _, rawLine := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(rawLine)
		if idx := strings.IndexAny(line, "#;"); idx >= 0 {
			line = strings.TrimSpace(line[:idx])
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			inGeneral = strings.TrimSpace(line[1:len(line)-1]) == "general"
			continue
		}
		if !inGeneral {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		if key != "api_base_url" {
			continue
		}
		value = strings.Trim(value, `"'`)
		return normalizeClerkBaseURL(value)
	}

	return ""
}

func clerkRequest(baseURL, endpoint, method string, payload any) (json.RawMessage, error) {
	normalizedBaseURL := normalizeClerkBaseURL(baseURL)
	if normalizedBaseURL == "" {
		return nil, nil
	}

	url := normalizedBaseURL + "/" + strings.TrimLeft(endpoint, "/")
	var body io.Reader
	if payload != nil {
		encoded, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		body = bytes.NewReader(encoded)
	}

	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("http status %d", resp.StatusCode)
	}

	return raw, nil
}

func clerkAlbumCacheKey(albumArtist, album, date string) string {
	if album == "" {
		return ""
	}
	return albumArtist + "\x1f" + album + "\x1f" + date
}

func fetchClerkAlbumCache(baseURL string, force bool) map[string]clerkAlbumRef {
	normalizedBaseURL := normalizeClerkBaseURL(baseURL)
	if normalizedBaseURL == "" {
		return map[string]clerkAlbumRef{}
	}

	now := time.Now()
	if !force && now.Before(clerkAlbumCacheExpiresAt) {
		return clerkAlbumCache
	}

	raw, err := clerkRequest(normalizedBaseURL, "albums", http.MethodGet, nil)
	if err != nil || raw == nil {
		if now.Before(clerkAlbumCacheExpiresAt) && len(clerkAlbumCache) > 0 {
			return clerkAlbumCache
		}
		return map[string]clerkAlbumRef{}
	}

	var response []map[string]any
	if err := json.Unmarshal(raw, &response); err != nil {
		if now.Before(clerkAlbumCacheExpiresAt) && len(clerkAlbumCache) > 0 {
			return clerkAlbumCache
		}
		return map[string]clerkAlbumRef{}
	}

	cache := map[string]clerkAlbumRef{}
	for _, album := range response {
		key := clerkAlbumCacheKey(stringValue(album["albumartist"]), stringValue(album["album"]), stringValue(album["date"]))
		if key == "" {
			continue
		}
		cache[key] = clerkAlbumRef{
			ID:     stringValue(album["id"]),
			Rating: normalizeRatingValue(stringValue(album["rating"])),
		}
	}

	clerkAlbumCache = cache
	clerkAlbumCacheExpiresAt = now.Add(clerkCacheTTL)
	return cache
}

func normalizeClerkAlbumEntry(album map[string]any) browserAlbumEntry {
	date := stringValue(album["date"])
	return browserAlbumEntry{
		ID:          stringValue(album["id"]),
		Album:       stringValue(album["album"]),
		AlbumArtist: stringValue(album["albumartist"]),
		Date:        date,
		Year:        extractYear(date),
		Rating:      normalizeRatingValue(stringValue(album["rating"])),
	}
}

func fetchClerkAlbumList(baseURL, mode string) ([]browserAlbumEntry, error) {
	normalizedBaseURL := normalizeClerkBaseURL(baseURL)
	if normalizedBaseURL == "" {
		return nil, errors.New("clerk API unavailable")
	}

	endpoint := "albums"
	if mode == "latest" {
		endpoint = "latest_albums"
	}

	raw, err := clerkRequest(normalizedBaseURL, endpoint, http.MethodGet, nil)
	if err != nil {
		return nil, err
	}
	if raw == nil {
		return []browserAlbumEntry{}, nil
	}

	var response []map[string]any
	if err := json.Unmarshal(raw, &response); err != nil {
		return []browserAlbumEntry{}, err
	}

	albums := make([]browserAlbumEntry, 0, len(response))
	for _, item := range response {
		entry := normalizeClerkAlbumEntry(item)
		if entry.ID != "" && entry.Album != "" {
			albums = append(albums, entry)
		}
	}
	return albums, nil
}

func stringValue(value any) string {
	switch typed := value.(type) {
	case nil:
		return ""
	case string:
		return typed
	case json.Number:
		return typed.String()
	case float64:
		if typed == float64(int64(typed)) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case int:
		return strconv.Itoa(typed)
	case int64:
		return strconv.FormatInt(typed, 10)
	case bool:
		if typed {
			return "true"
		}
		return "false"
	default:
		return fmt.Sprintf("%v", value)
	}
}

func newMPDClient(host string, port int, password string) (*mpdClient, error) {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 10*time.Second)
	if err != nil {
		return nil, err
	}

	client := &mpdClient{
		conn: conn,
		r:    bufio.NewReader(conn),
		w:    bufio.NewWriter(conn),
	}

	greeting, err := client.r.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, err
	}
	if !strings.HasPrefix(strings.TrimSpace(greeting), "OK MPD ") {
		conn.Close()
		return nil, fmt.Errorf("unexpected MPD greeting: %s", strings.TrimSpace(greeting))
	}

	if password != "" {
		if _, err := client.execLines("password", password); err != nil {
			conn.Close()
			return nil, err
		}
	}

	return client, nil
}

func (c *mpdClient) close() {
	if c == nil || c.conn == nil {
		return
	}
	_ = c.execNoResult("close")
	_ = c.conn.Close()
}

func quoteArg(value string) string {
	escaped := strings.ReplaceAll(value, `\`, `\\`)
	escaped = strings.ReplaceAll(escaped, `"`, `\"`)
	return `"` + escaped + `"`
}

func (c *mpdClient) send(command string, args ...string) error {
	var builder strings.Builder
	builder.WriteString(command)
	for _, arg := range args {
		builder.WriteByte(' ')
		builder.WriteString(quoteArg(arg))
	}
	builder.WriteByte('\n')
	if _, err := c.w.WriteString(builder.String()); err != nil {
		return err
	}
	return c.w.Flush()
}

func parseLine(line string) (string, string, bool) {
	parts := strings.SplitN(line, ": ", 2)
	if len(parts) != 2 {
		return "", "", false
	}
	return strings.ToLower(parts[0]), parts[1], true
}

func (c *mpdClient) execLines(command string, args ...string) ([]string, error) {
	if err := c.send(command, args...); err != nil {
		return nil, err
	}

	var lines []string
	for {
		rawLine, err := c.r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line := strings.TrimRight(rawLine, "\r\n")
		switch {
		case line == "OK":
			return lines, nil
		case strings.HasPrefix(line, "ACK "):
			return nil, errors.New(line)
		default:
			lines = append(lines, line)
		}
	}
}

func (c *mpdClient) execNoResult(command string, args ...string) error {
	_, err := c.execLines(command, args...)
	return err
}

func (c *mpdClient) execAttrs(command string, args ...string) (map[string]string, error) {
	lines, err := c.execLines(command, args...)
	if err != nil {
		return nil, err
	}
	attrs := map[string]string{}
	for _, line := range lines {
		key, value, ok := parseLine(line)
		if ok {
			attrs[key] = value
		}
	}
	return attrs, nil
}

func (c *mpdClient) execSongList(command string, args ...string) ([]map[string]string, error) {
	lines, err := c.execLines(command, args...)
	if err != nil {
		return nil, err
	}

	var songs []map[string]string
	var current map[string]string
	for _, line := range lines {
		key, value, ok := parseLine(line)
		if !ok {
			continue
		}
		if key == "file" {
			if current != nil {
				songs = append(songs, current)
			}
			current = map[string]string{}
		}
		if current == nil {
			current = map[string]string{}
		}
		current[key] = value
	}
	if current != nil {
		songs = append(songs, current)
	}
	return songs, nil
}

func (c *mpdClient) execBinary(command string, args ...string) (map[string]string, []byte, error) {
	if err := c.send(command, args...); err != nil {
		return nil, nil, err
	}

	attrs := map[string]string{}
	var chunk []byte
	for {
		rawLine, err := c.r.ReadString('\n')
		if err != nil {
			return nil, nil, err
		}
		line := strings.TrimRight(rawLine, "\r\n")
		switch {
		case line == "OK":
			return attrs, chunk, nil
		case strings.HasPrefix(line, "ACK "):
			return nil, nil, errors.New(line)
		case strings.HasPrefix(line, "binary: "):
			size, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "binary: ")))
			if err != nil {
				return nil, nil, err
			}
			chunk = make([]byte, size)
			if _, err := io.ReadFull(c.r, chunk); err != nil {
				return nil, nil, err
			}
			newline, err := c.r.ReadByte()
			if err != nil {
				return nil, nil, err
			}
			if newline != '\n' {
				return nil, nil, fmt.Errorf("unexpected binary terminator: %q", newline)
			}
		default:
			key, value, ok := parseLine(line)
			if ok {
				attrs[key] = value
			}
		}
	}
}

func (c *mpdClient) status() (map[string]string, error) {
	return c.execAttrs("status")
}

func (c *mpdClient) currentSong() (map[string]string, error) {
	return c.execAttrs("currentsong")
}

func (c *mpdClient) playlistInfo() ([]map[string]string, error) {
	return c.execSongList("playlistinfo")
}

func (c *mpdClient) find(tag, value string) ([]map[string]string, error) {
	return c.execSongList("find", tag, value)
}

func (c *mpdClient) idle(subsystems ...string) ([]string, error) {
	lines, err := c.execLines("idle", subsystems...)
	if err != nil {
		return nil, err
	}
	changes := make([]string, 0, len(lines))
	for _, line := range lines {
		key, value, ok := parseLine(line)
		if ok && key == "changed" {
			changes = append(changes, value)
		}
	}
	return changes, nil
}

func readSticker(client *mpdClient, filePath, name string) string {
	if filePath == "" {
		return ""
	}
	lines, err := client.execLines("sticker", "get", "song", filePath, name)
	if err != nil {
		return ""
	}
	for _, line := range lines {
		key, value, ok := parseLine(line)
		if !ok || key != "sticker" {
			continue
		}
		parts := strings.SplitN(value, "=", 2)
		if len(parts) == 2 {
			return parts[1]
		}
	}
	return ""
}

func detectImageExtension(blob []byte) string {
	switch {
	case len(blob) >= 8 && bytes.Equal(blob[:8], []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}):
		return ".png"
	case len(blob) >= 3 && blob[0] == 0xff && blob[1] == 0xd8 && blob[2] == 0xff:
		return ".jpg"
	case len(blob) >= 6 && (bytes.Equal(blob[:6], []byte("GIF87a")) || bytes.Equal(blob[:6], []byte("GIF89a"))):
		return ".gif"
	case len(blob) >= 12 && bytes.Equal(blob[:4], []byte("RIFF")) && bytes.Equal(blob[8:12], []byte("WEBP")):
		return ".webp"
	default:
		return ".img"
	}
}

func normalizeTrack(song map[string]string, stickers map[string]string) normalizedTrackData {
	filePath := song["file"]
	fileName := filepath.Base(filePath)
	if fileName == "." || fileName == "/" {
		fileName = filePath
	}
	track := song["track"]
	if idx := strings.Index(track, "/"); idx >= 0 {
		track = track[:idx]
	}
	date := song["date"]
	artist := song["artist"]
	if artist == "" {
		artist = song["name"]
	}
	return normalizedTrackData{
		TrackNumber: track,
		Artist:      artist,
		Title:       song["title"],
		Album:       song["album"],
		AlbumArtist: song["albumartist"],
		Date:        date,
		Year:        extractYear(date),
		FileName:    firstNonEmpty(fileName, filePath),
		Rating:      normalizeRatingValue(firstNonEmpty(stickers["rating"], song["rating"])),
		AlbumRating: normalizeRatingValue(firstNonEmpty(stickers["albumrating"], song["albumrating"])),
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func albumKey(song map[string]string) string {
	album := song["album"]
	albumArtist := firstNonEmpty(song["albumartist"], song["artist"], song["name"])
	if album == "" {
		return ""
	}
	return albumArtist + "\x1f" + album
}

func splitAlbumKey(value string) (string, string) {
	parts := strings.SplitN(value, "\x1f", 2)
	if len(parts) != 2 {
		return "", ""
	}
	return parts[0], parts[1]
}

func trackSortKey(song map[string]string) (int, int, string) {
	disc := song["disc"]
	if idx := strings.Index(disc, "/"); idx >= 0 {
		disc = disc[:idx]
	}
	track := song["track"]
	if idx := strings.Index(track, "/"); idx >= 0 {
		track = track[:idx]
	}
	discNum, _ := strconv.Atoi(firstNonEmpty(disc, "0"))
	trackNum, _ := strconv.Atoi(firstNonEmpty(track, "0"))
	return discNum, trackNum, firstNonEmpty(song["title"], song["file"])
}

func sortSongsByTrack(songs []map[string]string) {
	sort.SliceStable(songs, func(i, j int) bool {
		id, it, ititle := trackSortKey(songs[i])
		jd, jt, jtitle := trackSortKey(songs[j])
		if id != jd {
			return id < jd
		}
		if it != jt {
			return it < jt
		}
		return ititle < jtitle
	})
}

func buildAlbumInfoForValues(client *mpdClient, albumArtist, album, date, currentFile string, clerkCache map[string]clerkAlbumRef) albumInfo {
	if album == "" {
		return defaultAlbumInfo()
	}

	matches, err := client.find("album", album)
	if err != nil {
		return defaultAlbumInfo()
	}

	if albumArtist != "" {
		filtered := make([]map[string]string, 0, len(matches))
		for _, item := range matches {
			if item["albumartist"] == albumArtist {
				filtered = append(filtered, item)
			}
		}
		if len(filtered) > 0 {
			matches = filtered
		}
	}

	if date != "" {
		filtered := make([]map[string]string, 0, len(matches))
		for _, item := range matches {
			if item["date"] == date {
				filtered = append(filtered, item)
			}
		}
		if len(filtered) > 0 {
			matches = filtered
		}
	}

	sortSongsByTrack(matches)
	if len(matches) > 0 {
		date = matches[0]["date"]
	}
	year := extractYear(date)
	clerkEntry := clerkCache[clerkAlbumCacheKey(albumArtist, album, date)]

	tracks := make([]albumTrack, 0, len(matches))
	files := make([]string, 0, len(matches))
	currentIndex := -1
	for index, item := range matches {
		track := normalizeTrack(item, nil)
		itemFile := item["file"]
		files = append(files, itemFile)
		if itemFile != "" && itemFile == currentFile {
			currentIndex = index
		}
		tracks = append(tracks, albumTrack{
			TrackNumber: track.TrackNumber,
			Title:       firstNonEmpty(track.Title, track.FileName),
		})
	}

	artSong := map[string]string{}
	if currentIndex >= 0 && currentIndex < len(matches) {
		artSong = matches[currentIndex]
	} else if len(matches) > 0 {
		artSong = matches[0]
	}
	artPath := cacheAlbumArt(client, artSong)

	return albumInfo{
		Title:       album,
		AlbumArtist: albumArtist,
		Year:        year,
		AlbumRating: clerkEntry.Rating,
		ClerkID:     clerkEntry.ID,
		ArtPath:     artPath,
		TrackCount:  len(tracks),
		Tracks:      tracks,
		Files:       files,
		CurrentIdx:  currentIndex,
	}
}

func buildAlbumInfo(client *mpdClient, song map[string]string, clerkCache map[string]clerkAlbumRef) albumInfo {
	return buildAlbumInfoForValues(client, song["albumartist"], song["album"], song["date"], song["file"], clerkCache)
}

func buildQueueSnapshot(client *mpdClient, status map[string]string, clerkCache map[string]clerkAlbumRef) (queueInfo, map[string]albumInfo) {
	currentPos, _ := strconv.Atoi(firstNonEmpty(status["song"], "-1"))
	playlist, err := client.playlistInfo()
	if err != nil {
		return queueInfo{CurrentPos: -1, Tracks: []queueTrack{}}, map[string]albumInfo{}
	}

	queue := make([]queueTrack, 0, len(playlist))
	albumDetails := map[string]albumInfo{}
	for _, item := range playlist {
		track := normalizeTrack(item, nil)
		key := albumKey(item)
		pos, _ := strconv.Atoi(firstNonEmpty(item["pos"], "-1"))
		if key != "" {
			if _, exists := albumDetails[key]; !exists {
				albumDetails[key] = buildAlbumInfo(client, item, clerkCache)
			}
		}
		queue = append(queue, queueTrack{
			Pos:         pos,
			TrackNumber: track.TrackNumber,
			Artist:      track.Artist,
			AlbumArtist: track.AlbumArtist,
			Title:       firstNonEmpty(track.Title, track.FileName),
			Album:       track.Album,
			AlbumKey:    key,
			Current:     pos == currentPos,
		})
	}

	return queueInfo{
		CurrentPos: currentPos,
		Tracks:     queue,
	}, albumDetails
}

func buildArtistAlbumMap(client *mpdClient, artistNames map[string]struct{}, currentSong map[string]string, clerkCache map[string]clerkAlbumRef) (map[string][]artistAlbumInfo, map[string]albumInfo) {
	artistAlbums := map[string][]artistAlbumInfo{}
	albumDetails := map[string]albumInfo{}
	currentSongKey := albumKey(currentSong)
	currentSongDate := currentSong["date"]
	currentSongFile := currentSong["file"]

	names := make([]string, 0, len(artistNames))
	for name := range artistNames {
		if strings.TrimSpace(name) != "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)

	for _, artistName := range names {
		matches, err := client.find("albumartist", artistName)
		if err != nil || len(matches) == 0 {
			matches, _ = client.find("artist", artistName)
		}

		albumsForArtist := []artistAlbumInfo{}
		seenAlbumKeys := map[string]struct{}{}
		for _, item := range matches {
			key := albumKey(item)
			if key == "" {
				continue
			}
			if _, exists := seenAlbumKeys[key]; exists {
				continue
			}
			seenAlbumKeys[key] = struct{}{}

			itemCurrentFile := ""
			if key == currentSongKey && item["date"] == currentSongDate {
				itemCurrentFile = currentSongFile
			}

			info := buildAlbumInfoForValues(client, firstNonEmpty(item["albumartist"], item["artist"], item["name"]), item["album"], item["date"], itemCurrentFile, clerkCache)
			albumDetails[key] = info
			albumsForArtist = append(albumsForArtist, artistAlbumInfo{
				AlbumKey:    key,
				Title:       info.Title,
				Year:        info.Year,
				AlbumRating: info.AlbumRating,
				TrackCount:  info.TrackCount,
			})
		}

		sort.SliceStable(albumsForArtist, func(i, j int) bool {
			if albumsForArtist[i].Year != albumsForArtist[j].Year {
				return albumsForArtist[i].Year > albumsForArtist[j].Year
			}
			return albumsForArtist[i].Title > albumsForArtist[j].Title
		})
		artistAlbums[artistName] = albumsForArtist
	}

	return artistAlbums, albumDetails
}

func readArtBlob(client *mpdClient, filePath string) []byte {
	if filePath == "" {
		return nil
	}

	for _, commandName := range []string{"albumart", "readpicture"} {
		var all []byte
		offset := 0
		for {
			attrs, chunk, err := client.execBinary(commandName, filePath, strconv.Itoa(offset))
			if err != nil {
				all = nil
				break
			}
			all = append(all, chunk...)
			size, _ := strconv.Atoi(attrs["size"])
			if len(chunk) == 0 || size == 0 || len(all) >= size {
				break
			}
			offset = len(all)
		}
		if len(all) > 0 {
			return all
		}
	}

	return nil
}

func cacheAlbumArt(client *mpdClient, song map[string]string) string {
	filePath := song["file"]
	if filePath == "" {
		return ""
	}

	blob := readArtBlob(client, filePath)
	if len(blob) == 0 {
		return ""
	}

	digest := sha1.Sum(append([]byte(filePath+"\x00"), blobPrefix(blob, 256)...))
	extension := detectImageExtension(blob)
	artDir := filepath.Join(os.TempDir(), "dank-plugin-mpd")
	if err := os.MkdirAll(artDir, 0o755); err != nil {
		return ""
	}
	artPath := filepath.Join(artDir, fmt.Sprintf("%x%s", digest, extension))
	if _, err := os.Stat(artPath); err == nil {
		return artPath
	}
	if err := os.WriteFile(artPath, blob, 0o644); err != nil {
		return ""
	}
	return artPath
}

func blobPrefix(blob []byte, max int) []byte {
	if len(blob) <= max {
		return blob
	}
	return blob[:max]
}

func snapshot(client *mpdClient, artPath, clerkBaseURL string) snapshotPayload {
	status, err := client.status()
	if err != nil {
		return disconnectedSnapshot(err)
	}
	song, err := client.currentSong()
	if err != nil {
		return disconnectedSnapshot(err)
	}

	songStickers := map[string]string{
		"rating":      readSticker(client, song["file"], "rating"),
		"albumrating": readSticker(client, song["file"], "albumrating"),
	}
	clerkCache := fetchClerkAlbumCache(clerkBaseURL, false)
	queue, albumDetails := buildQueueSnapshot(client, status, clerkCache)

	artistNames := map[string]struct{}{}
	for _, artistName := range []string{song["artist"], song["albumartist"], song["name"]} {
		if artistName != "" {
			artistNames[artistName] = struct{}{}
		}
	}
	for _, item := range queue.Tracks {
		if item.Artist != "" {
			artistNames[item.Artist] = struct{}{}
		}
		if item.AlbumArtist != "" {
			artistNames[item.AlbumArtist] = struct{}{}
		}
	}

	artistAlbums, artistAlbumDetails := buildArtistAlbumMap(client, artistNames, song, clerkCache)
	for key, value := range artistAlbumDetails {
		albumDetails[key] = value
	}

	return snapshotPayload{
		Type:         "snapshot",
		Connected:    true,
		State:        firstNonEmpty(status["state"], "stop"),
		Track:        normalizeTrack(song, songStickers),
		AlbumInfo:    buildAlbumInfo(client, song, clerkCache),
		QueueInfo:    queue,
		ArtistAlbums: artistAlbums,
		AlbumDetails: albumDetails,
		ArtPath:      artPath,
		Error:        "",
	}
}

func disconnectedSnapshot(err error) snapshotPayload {
	return snapshotPayload{
		Type:         "snapshot",
		Connected:    false,
		State:        "disconnected",
		Track:        normalizeTrack(map[string]string{}, nil),
		AlbumInfo:    defaultAlbumInfo(),
		QueueInfo:    queueInfo{CurrentPos: -1, Tracks: []queueTrack{}},
		ArtistAlbums: map[string][]artistAlbumInfo{},
		AlbumDetails: map[string]albumInfo{},
		ArtPath:      "",
		Error:        err.Error(),
	}
}

func defaultAlbumInfo() albumInfo {
	return albumInfo{
		Title:       "",
		AlbumArtist: "",
		Year:        "",
		AlbumRating: "",
		ClerkID:     "",
		ArtPath:     "",
		TrackCount:  0,
		Tracks:      []albumTrack{},
		Files:       []string{},
		CurrentIdx:  -1,
	}
}

func resolveHostAndPassword(hostArg, passwordArg string) (string, string) {
	host := hostArg
	if host == "" {
		host = firstNonEmpty(os.Getenv("MPD_HOST"), "localhost")
	}
	password := passwordArg
	if strings.Contains(host, "@") && password == "" {
		parts := strings.SplitN(host, "@", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			password = parts[0]
			host = parts[1]
		}
	}
	return host, password
}

func isValidRatingValue(value string) bool {
	switch value {
	case "Delete", "---":
		return true
	}
	for i := 1; i <= 10; i++ {
		if value == strconv.Itoa(i) {
			return true
		}
	}
	return false
}

func performAction(host string, port int, password, action, arg, clerkBaseURL string) error {
	switch action {
	case "dump_albums":
		mode := "album"
		if strings.ToLower(strings.TrimSpace(arg)) == "latest" {
			mode = "latest"
		}
		albums, err := fetchClerkAlbumList(clerkBaseURL, mode)
		errorText := ""
		if err != nil {
			errorText = "Clerk API unavailable."
			albums = []browserAlbumEntry{}
		}
		emit(albumBrowserPayload{
			Type:   "album_browser",
			Mode:   mode,
			Albums: albums,
			Error:  errorText,
		})
		return nil
	case "queue_clerk_album":
		if arg == "" {
			return nil
		}
		parts := strings.SplitN(arg, ":", 3)
		if len(parts) < 2 {
			return nil
		}
		queueMode := strings.ToLower(strings.TrimSpace(parts[0]))
		albumID := strings.TrimSpace(parts[1])
		listMode := "album"
		if len(parts) > 2 && strings.ToLower(strings.TrimSpace(parts[2])) == "latest" {
			listMode = "latest"
		}
		if (queueMode != "add" && queueMode != "insert" && queueMode != "replace") || albumID == "" {
			return nil
		}
		_, _ = clerkRequest(clerkBaseURL, "playlist/add/album/"+albumID, http.MethodPost, map[string]string{
			"mode":      queueMode,
			"list_mode": listMode,
		})
		return nil
	case "random_album":
		_, _ = clerkRequest(clerkBaseURL, "playback/random/album", http.MethodPost, map[string]string{})
		return nil
	case "random_tracks":
		_, _ = clerkRequest(clerkBaseURL, "playback/random/tracks", http.MethodPost, map[string]string{})
		return nil
	case "set_album_rating":
		if arg == "" {
			return nil
		}
		parts := strings.SplitN(arg, ":", 2)
		if len(parts) != 2 {
			return nil
		}
		albumID := parts[0]
		ratingValue := parts[1]
		if albumID != "" && isValidRatingValue(ratingValue) {
			_, _ = clerkRequest(clerkBaseURL, "albums/"+albumID+"/rating", http.MethodPost, map[string]string{
				"rating": ratingValue,
			})
		}
		return nil
	}

	client, err := newMPDClient(host, port, password)
	if err != nil {
		return err
	}
	defer client.close()

	song, _ := client.currentSong()
	var info albumInfo
	if (action == "add_album" || action == "insert_album" || action == "replace_album") && arg != "" {
		albumArtist, album := splitAlbumKey(arg)
		info = buildAlbumInfoForValues(client, albumArtist, album, "", "", nil)
	} else {
		info = buildAlbumInfo(client, song, nil)
	}

	switch action {
	case "toggle":
		status, err := client.status()
		if err != nil {
			return err
		}
		switch status["state"] {
		case "play":
			return client.execNoResult("pause", "1")
		case "pause":
			return client.execNoResult("pause", "0")
		default:
			return client.execNoResult("play")
		}
	case "stop":
		return client.execNoResult("stop")
	case "next":
		return client.execNoResult("next")
	case "previous":
		return client.execNoResult("previous")
	case "play_pos":
		if arg == "" {
			return nil
		}
		return client.execNoResult("play", arg)
	case "set_track_rating":
		if !isValidRatingValue(arg) {
			return nil
		}
		trackFile := song["file"]
		if trackFile == "" {
			return nil
		}
		switch arg {
		case "Delete":
			return client.execNoResult("sticker", "delete", "song", trackFile, "rating")
		case "---":
			return nil
		default:
			return client.execNoResult("sticker", "set", "song", trackFile, "rating", arg)
		}
	case "add_album":
		for _, filePath := range info.Files {
			if filePath != "" {
				if err := client.execNoResult("add", filePath); err != nil {
					return err
				}
			}
		}
	case "insert_album":
		status, err := client.status()
		if err != nil {
			return err
		}
		insertPos, err := strconv.Atoi(status["song"])
		if err != nil {
			insertPos = len(info.Files)
		} else {
			insertPos++
		}
		for offset, filePath := range info.Files {
			if filePath != "" {
				if err := client.execNoResult("addid", filePath, strconv.Itoa(insertPos+offset)); err != nil {
					return err
				}
			}
		}
	case "replace_album":
		files := make([]string, 0, len(info.Files))
		for _, filePath := range info.Files {
			if filePath != "" {
				files = append(files, filePath)
			}
		}
		if err := client.execNoResult("clear"); err != nil {
			return err
		}
		for _, filePath := range files {
			if err := client.execNoResult("add", filePath); err != nil {
				return err
			}
		}
		if len(files) > 0 {
			playIndex := 0
			if info.CurrentIdx >= 0 {
				playIndex = info.CurrentIdx
			}
			return client.execNoResult("play", strconv.Itoa(playIndex))
		}
	}

	return nil
}

func watcherLoop(host string, port int, password, clerkBaseURL string) {
	for {
		client, err := newMPDClient(host, port, password)
		if err != nil {
			emit(disconnectedSnapshot(err))
			time.Sleep(2 * time.Second)
			continue
		}

		func() {
			defer client.close()

			song, _ := client.currentSong()
			artPath := cacheAlbumArt(client, song)
			emit(snapshot(client, artPath, clerkBaseURL))

			for {
				changes, err := client.idle("player", "playlist", "options")
				if err != nil {
					emit(disconnectedSnapshot(err))
					time.Sleep(2 * time.Second)
					return
				}
				song, _ = client.currentSong()
				if len(changes) == 0 || contains(changes, "player") || contains(changes, "playlist") {
					artPath = cacheAlbumArt(client, song)
				}
				emit(snapshot(client, artPath, clerkBaseURL))
			}
		}()
	}
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func main() {
	hostFlag := flag.String("host", "", "")
	portDefault := 6600
	if envPort := os.Getenv("MPD_PORT"); envPort != "" {
		if parsed, err := strconv.Atoi(envPort); err == nil {
			portDefault = parsed
		}
	}
	portFlag := flag.Int("port", portDefault, "")
	passwordFlag := flag.String("password", "", "")
	clerkFlag := flag.String("clerk-api-base-url", "", "")
	actionFlag := flag.String("action", "", "")
	argFlag := flag.String("arg", "", "")
	flag.Parse()

	host, password := resolveHostAndPassword(*hostFlag, *passwordFlag)
	clerkAPIBaseURL := resolveClerkAPIBaseURL(*clerkFlag)
	if *actionFlag != "" {
		if err := performAction(host, *portFlag, password, *actionFlag, *argFlag, clerkAPIBaseURL); err != nil {
			os.Exit(1)
		}
		return
	}

	watcherLoop(host, *portFlag, password, clerkAPIBaseURL)
}
