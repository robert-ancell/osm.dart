/// The version of this package, as its pubspec gives it.
///
/// Written out here rather than read from `pubspec.yaml`, which is not around
/// at run time: a published package is source on disk, or compiled into
/// something with no files next to it at all. `test/version_test.dart` reads
/// the pubspec and fails if the two ever disagree, so bumping one without the
/// other cannot get past the tests.
const String packageVersion = '0.1.0';
