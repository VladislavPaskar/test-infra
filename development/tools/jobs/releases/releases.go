// Code generated by rendertemplates. DO NOT EDIT.

package releases

// List of currently supported releases
var (
	Release210 = mustParse("2.10")
	Release29  = mustParse("2.9")
	Release28  = mustParse("2.8")
	Release27  = mustParse("2.7")
)

// GetAllKymaReleases returns all supported kyma release branches
func GetAllKymaReleases() []*SupportedRelease {
	return []*SupportedRelease{
		Release29,
		Release28,
		Release27,
	}
}

// GetNextKymaRelease returns the version of kyma currently under development
func GetNextKymaRelease() *SupportedRelease {
	return Release210
}
