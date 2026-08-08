// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Haven Hub';

  @override
  String get home => 'Home';

  @override
  String get mine => 'Mine';

  @override
  String get login => 'Login';

  @override
  String get logout => 'Logout';

  @override
  String get profile => 'Profile';

  @override
  String get settings => 'Settings';

  @override
  String get houseManagement => 'House Management';

  @override
  String get myHouses => 'My Houses';

  @override
  String get repair => 'Repairs';

  @override
  String get visitorRegistration => 'Visitor Registration';

  @override
  String get communityTitle => 'Community';

  @override
  String get offlineNotice =>
      'Offline sample content is shown until the latest announcements load.';

  @override
  String get announcementLoadFailed =>
      'Announcements could not be loaded. Please try again.';

  @override
  String get announcementDetailLoadFailed =>
      'Announcement details could not be loaded. Please try again.';

  @override
  String get idPhotoFormatError =>
      'Only JPG, JPEG, and PNG identity photos are supported.';

  @override
  String get idPhotoTooLarge => 'An identity photo cannot exceed 8 MB.';

  @override
  String get addHouse => 'Add House';

  @override
  String get editHouse => 'Edit House';

  @override
  String get houseDetail => 'House Detail';

  @override
  String get deleteHouse => 'Delete House';

  @override
  String get community => 'Community';

  @override
  String get building => 'Building';

  @override
  String get room => 'Room';

  @override
  String get ownerName => 'Owner Name';

  @override
  String get gender => 'Gender';

  @override
  String get male => 'Male';

  @override
  String get female => 'Female';

  @override
  String get mobile => 'Mobile';

  @override
  String get idCard => 'ID Card';

  @override
  String get selectCommunity => 'Select Community';

  @override
  String get selectBuilding => 'Select Building';

  @override
  String get selectRoom => 'Select Room';

  @override
  String get submit => 'Submit';

  @override
  String get submitForReview => 'Submit for Review';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Confirm';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get edit => 'Edit';

  @override
  String get refresh => 'Refresh';

  @override
  String get retry => 'Retry';

  @override
  String get back => 'Back';

  @override
  String get loading => 'Loading...';

  @override
  String get loadingFailed => 'Loading Failed';

  @override
  String get noData => 'No Data';

  @override
  String get networkError => 'Network Error';

  @override
  String get serverError => 'Server Error';

  @override
  String get success => 'Success';

  @override
  String get failed => 'Failed';

  @override
  String get addSuccess => 'Added Successfully';

  @override
  String get updateSuccess => 'Updated Successfully';

  @override
  String get deleteSuccess => 'Deleted Successfully';

  @override
  String get pleaseEnter => 'Please enter';

  @override
  String get pleaseSelect => 'Please select';

  @override
  String get required => 'Required';

  @override
  String errorRequired(String field) {
    return '$field is required';
  }

  @override
  String errorInvalidFormat(String field) {
    return 'Invalid $field format';
  }

  @override
  String errorMinLength(String field, int min) {
    return '$field must be at least $min characters';
  }

  @override
  String errorMaxLength(String field, int max) {
    return '$field must not exceed $max characters';
  }

  @override
  String get uploadPhoto => 'Upload Photo';

  @override
  String get takePhoto => 'Take Photo';

  @override
  String get chooseFromGallery => 'Choose from Gallery';

  @override
  String get uploadIdCardFront => 'Upload ID Card Front';

  @override
  String get uploadIdCardBack => 'Upload ID Card Back';

  @override
  String get houseStatus => 'House Status';

  @override
  String get statusPending => 'Pending';

  @override
  String get statusApproved => 'Approved';

  @override
  String get statusRejected => 'Rejected';

  @override
  String get confirmDelete => 'Confirm Delete?';

  @override
  String get confirmDeleteMessage => 'This action cannot be undone';

  @override
  String get announcement => 'Announcement';

  @override
  String get announcementDetail => 'Announcement Detail';

  @override
  String get noAnnouncement => 'No Announcements';

  @override
  String get location => 'Location';

  @override
  String get currentLocation => 'Current Location';

  @override
  String get relocate => 'Relocate';

  @override
  String get nearbyCommunities => 'Nearby Communities';

  @override
  String get pageLoadError => 'Page Load Error';

  @override
  String get pageLoadErrorMessage =>
      'Sorry, the page encountered some problems';

  @override
  String get reload => 'Reload';

  @override
  String get viewDetails => 'View Details';

  @override
  String get errorDetails => 'Error Details';

  @override
  String get errorMessage => 'Error Message';

  @override
  String get stackTrace => 'Stack Trace';

  @override
  String get close => 'Close';
}
