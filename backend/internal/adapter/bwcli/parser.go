package bwcli

import (
	"encoding/json"
)

// parseSummaries decodes the JSON array `bw list items --search ...` returns.
// Strips secret fields server-side before returning.
func parseSummaries(out string) []ItemSummary {
	var raw []struct {
		ID     string `json:"id"`
		Name   string `json:"name"`
		Type   int    `json:"type"`
		FolderID string `json:"folderId"`
		Login  *struct {
			URIs []struct {
				URI string `json:"uri"`
			} `json:"uris"`
		} `json:"login"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil
	}
	results := make([]ItemSummary, 0, len(raw))
	for _, r := range raw {
		s := ItemSummary{
			ID:     r.ID,
			Name:   r.Name,
			Folder: r.FolderID,
			Type:   itemTypeLabel(r.Type),
		}
		if r.Login != nil {
			for _, u := range r.Login.URIs {
				s.URIs = append(s.URIs, u.URI)
			}
		}
		results = append(results, s)
	}
	return results
}

// parseItem decodes the single-item JSON `bw get item <id>` returns.
func parseItem(out string) (*Item, error) {
	var r struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Notes string `json:"notes"`
		Login *struct {
			Username string `json:"username"`
			Password string `json:"password"`
			TOTP     string `json:"totp"`
			URIs     []struct {
				URI string `json:"uri"`
			} `json:"uris"`
		} `json:"login"`
		Fields []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
			Type  int    `json:"type"`
		} `json:"fields"`
		FolderID string `json:"folderId"`
	}
	if err := json.Unmarshal([]byte(out), &r); err != nil {
		return nil, err
	}
	item := &Item{
		ID:     r.ID,
		Name:   r.Name,
		Folder: r.FolderID,
		Notes:  r.Notes,
	}
	if r.Login != nil {
		item.Username = r.Login.Username
		item.Password = r.Login.Password
		item.TOTP = r.Login.TOTP
		for _, u := range r.Login.URIs {
			item.URIs = append(item.URIs, u.URI)
		}
	}
	if len(r.Fields) > 0 {
		item.Fields = make(map[string]string, len(r.Fields))
		for _, f := range r.Fields {
			// Type 1 = hidden. We pass through here; Get() strips ALL when
			// reveal=false anyway.
			item.Fields[f.Name] = f.Value
		}
	}
	return item, nil
}

// parseFolders decodes the JSON array `bw list folders` returns. The
// implicit "No Folder" entry has a null id — we surface it as id="" so
// the caller sees a stable string type.
func parseFolders(out string) []Folder {
	var raw []struct {
		ID   *string `json:"id"`
		Name string  `json:"name"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil
	}
	results := make([]Folder, 0, len(raw))
	for _, r := range raw {
		f := Folder{Name: r.Name}
		if r.ID != nil {
			f.ID = *r.ID
		}
		results = append(results, f)
	}
	return results
}

func itemTypeLabel(t int) string {
	switch t {
	case 1:
		return "login"
	case 2:
		return "secureNote"
	case 3:
		return "card"
	case 4:
		return "identity"
	default:
		return "unknown"
	}
}
