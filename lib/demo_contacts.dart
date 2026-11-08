import 'profile/user_profile.dart';

class DemoContact {
  const DemoContact({
    required this.id,
    required this.name,
    required this.occupation,
    required this.summary,
    required this.skills,
    required this.searchingSkills,
  });
  final String id;
  final String name;
  final String occupation;
  final String summary;
  final List<String> skills;
  final List<String> searchingSkills;
  String get photoAsset => 'assets/people/$id.png';
  UserProfile get profile => UserProfile(
    name: name,
    occupation: occupation,
    summary: summary,
    skills: skills,
    searchingSkills: searchingSkills,
  );
}

// Fictional sample contacts. They are independent of the locally edited profile.
const demoContacts = [
  DemoContact(
    id: 'maya-chen',
    name: 'Maya Chen',
    occupation: 'Product Designer',
    summary:
        'I design digital products that make complex tasks easier to understand and complete. My work connects user research, clear interfaces, and practical business goals.\n\n'
        'I enjoy working with founders and development teams from early discovery through interactive prototypes and design handoff.',
    skills: [
      'Product Design',
      'UX Research',
      'UI Design',
      'Figma',
      'Prototyping',
      'Design Systems',
      'User Interviews',
      'Usability Testing',
      'Wireframing',
      'User Flows',
      'Interaction Design',
      'Accessibility',
      'Information Architecture',
      'Responsive Design',
      'Design Handoff',
    ],
    searchingSkills: [
      'Frontend Development',
      'Flutter',
      'Backend Development',
      'UX Writing',
      'Motion Design',
      'Illustration',
      'Product Analytics',
      'QA Testing',
      'Brand Strategy',
      'User Recruitment',
      'Project Management',
      'API Integration',
    ],
  ),
  DemoContact(
    id: 'daniel-brooks',
    name: 'Daniel Brooks',
    occupation: 'Flutter Developer',
    summary:
        'I build mobile applications with Flutter, from the first working prototype to a release-ready product. I focus on readable code, responsive interfaces, and reliable integrations.\n\n'
        'I like collaborating with designers and product teams to turn clear requirements into apps that are straightforward to use and maintain.',
    skills: [
      'Flutter',
      'Dart',
      'Mobile Development',
      'Firebase',
      'REST APIs',
      'State Management',
      'Riverpod',
      'App Architecture',
      'Widget Testing',
      'Unit Testing',
      'Git',
      'CI/CD',
      'Push Notifications',
      'Offline Storage',
      'Performance Optimization',
    ],
    searchingSkills: [
      'Product Design',
      'UX Research',
      'UI Design',
      'Backend Development',
      'API Design',
      'QA Testing',
      'Test Automation',
      'App Store Optimization',
      'Copywriting',
      'Illustration',
      'Product Management',
      'Security Review',
    ],
  ),
  DemoContact(
    id: 'sofia-martinez',
    name: 'Sofia Martinez',
    occupation: 'Photographer',
    summary:
        'I create natural portraits and visual stories for people, independent brands, and small businesses. I help plan each shoot around the subject, the setting, and where the images will be used.\n\n'
        'My approach combines a relaxed shooting experience with thoughtful lighting, consistent editing, and a clear visual direction.',
    skills: [
      'Portrait Photography',
      'Brand Photography',
      'Product Photography',
      'Event Photography',
      'Photo Editing',
      'Lightroom',
      'Photoshop',
      'Studio Lighting',
      'Natural Light',
      'Retouching',
      'Color Grading',
      'Art Direction',
      'Location Scouting',
      'Photo Selection',
      'Visual Storytelling',
    ],
    searchingSkills: [
      'Makeup Artistry',
      'Hair Styling',
      'Wardrobe Styling',
      'Set Design',
      'Videography',
      'Video Editing',
      'Graphic Design',
      'Social Media',
      'Web Design',
      'Copywriting',
      'Print Production',
      'Event Planning',
    ],
  ),
  DemoContact(
    id: 'ethan-williams',
    name: 'Ethan Williams',
    occupation: 'Electrician',
    summary:
        'I help homeowners and small businesses plan electrical work, identify faults, and keep installations organized and practical. I value clear communication, careful preparation, and a tidy work area.\n\n'
        'I am interested in collaborating with other trades on renovations, lighting projects, and smart home installations.',
    skills: [
      'Electrical Installation',
      'Fault Finding',
      'Lighting Installation',
      'Wiring',
      'Circuit Testing',
      'Electrical Maintenance',
      'Cable Routing',
      'Smart Lighting',
      'Socket Installation',
      'Switch Installation',
      'Wiring Diagrams',
      'Project Estimation',
      'Outdoor Lighting',
      'Renovation Planning',
      'Site Coordination',
    ],
    searchingSkills: [
      'Carpentry',
      'Plumbing',
      'Interior Design',
      'Painting',
      'Plastering',
      'Tiling',
      'Home Automation',
      'Network Installation',
      'Landscaping',
      'Project Management',
      'Photography',
      'Bookkeeping',
    ],
  ),
  DemoContact(
    id: 'amara-johnson',
    name: 'Amara Johnson',
    occupation: 'Marketing Specialist',
    summary:
        'I help small businesses explain their offer and reach the right audience. I connect customer research, content planning, and campaign measurement so marketing decisions have a clear purpose.\n\n'
        'I enjoy working with creative and technical specialists to develop useful content, improve landing pages, and learn from campaign results.',
    skills: [
      'Marketing Strategy',
      'Content Marketing',
      'Customer Research',
      'Social Media',
      'Email Marketing',
      'Copywriting',
      'SEO',
      'Campaign Planning',
      'Marketing Analytics',
      'Brand Positioning',
      'Content Calendars',
      'Landing Pages',
      'A/B Testing',
      'Audience Segmentation',
      'Competitor Research',
    ],
    searchingSkills: [
      'Graphic Design',
      'Photography',
      'Video Production',
      'Motion Design',
      'Web Development',
      'UX Research',
      'Data Analytics',
      'Illustration',
      'Translation',
      'CRM Integration',
      'Event Planning',
      'Product Design',
    ],
  ),
];

// A new person appears in Chat first; replying connects her to Contacts.
const demoChatContact = DemoContact(
  id: 'julia-robinson',
  name: 'Julia Robinson',
  occupation: 'UI/UX Designer',
  summary:
      'I create clear, approachable interfaces for websites and mobile apps. I combine user research, prototyping, and visual design to help teams turn ideas into useful products.\n\n'
      'I enjoy collaborating with developers and product teams, sharing feedback early, and refining the details that make an experience feel simple.',
  skills: [
    'UI Design',
    'UX Research',
    'Figma',
    'Prototyping',
    'Wireframing',
    'Design Systems',
    'User Flows',
    'Usability Testing',
    'Interaction Design',
    'Responsive Design',
    'Accessibility',
    'Design Handoff',
  ],
  searchingSkills: [
    'Flutter',
    'Frontend Development',
    'Backend Development',
    'UX Writing',
    'Motion Design',
    'Illustration',
    'Product Analytics',
    'QA Testing',
    'Copywriting',
    'Brand Strategy',
    'Photography',
    'Project Management',
  ],
);

final demoPeople = {
  for (final contact in [...demoContacts, demoChatContact]) contact.id: contact,
};
