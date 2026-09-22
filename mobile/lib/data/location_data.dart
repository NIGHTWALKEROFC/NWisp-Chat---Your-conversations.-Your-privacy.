/// Built-in place lists for the optional "where is this community?" fields
/// (country → state → district).
///
/// Complete for: every country, and every Indian state / union territory
/// with its districts. For any OTHER country the state and district are
/// typed in by hand (see LocationFields) — a full worldwide district list
/// would be huge and go out of date. Every level is optional.
class LocationData {
  LocationData._();

  static const indiaName = 'India';

  static final List<String> countries = _split(_countries);

  static final List<String> indiaStates = _indiaDistricts.keys.toList()..sort();

  static List<String> districtsOfIndianState(String state) {
    final raw = _indiaDistricts[state];
    return raw == null ? const [] : _split(raw);
  }

  static bool isIndia(String? country) => (country ?? '').trim().toLowerCase() == 'india';

  static List<String> _split(String s) => s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  static const _countries =
      'Afghanistan, Albania, Algeria, Andorra, Angola, Antigua and Barbuda, Argentina, Armenia, Australia, Austria, '
      'Azerbaijan, Bahamas, Bahrain, Bangladesh, Barbados, Belarus, Belgium, Belize, Benin, Bhutan, Bolivia, '
      'Bosnia and Herzegovina, Botswana, Brazil, Brunei, Bulgaria, Burkina Faso, Burundi, Cabo Verde, Cambodia, '
      'Cameroon, Canada, Central African Republic, Chad, Chile, China, Colombia, Comoros, Congo (Republic), '
      'Congo (Democratic Republic), Costa Rica, Croatia, Cuba, Cyprus, Czechia, Denmark, Djibouti, Dominica, '
      'Dominican Republic, Ecuador, Egypt, El Salvador, Equatorial Guinea, Eritrea, Estonia, Eswatini, Ethiopia, '
      'Fiji, Finland, France, Gabon, Gambia, Georgia, Germany, Ghana, Greece, Grenada, Guatemala, Guinea, '
      'Guinea-Bissau, Guyana, Haiti, Honduras, Hungary, Iceland, India, Indonesia, Iran, Iraq, Ireland, Israel, '
      'Italy, Ivory Coast, Jamaica, Japan, Jordan, Kazakhstan, Kenya, Kiribati, Kosovo, Kuwait, Kyrgyzstan, Laos, '
      'Latvia, Lebanon, Lesotho, Liberia, Libya, Liechtenstein, Lithuania, Luxembourg, Madagascar, Malawi, '
      'Malaysia, Maldives, Mali, Malta, Marshall Islands, Mauritania, Mauritius, Mexico, Micronesia, Moldova, '
      'Monaco, Mongolia, Montenegro, Morocco, Mozambique, Myanmar, Namibia, Nauru, Nepal, Netherlands, '
      'New Zealand, Nicaragua, Niger, Nigeria, North Korea, North Macedonia, Norway, Oman, Pakistan, Palau, '
      'Palestine, Panama, Papua New Guinea, Paraguay, Peru, Philippines, Poland, Portugal, Qatar, Romania, Russia, '
      'Rwanda, Saint Kitts and Nevis, Saint Lucia, Saint Vincent and the Grenadines, Samoa, San Marino, '
      'Sao Tome and Principe, Saudi Arabia, Senegal, Serbia, Seychelles, Sierra Leone, Singapore, Slovakia, '
      'Slovenia, Solomon Islands, Somalia, South Africa, South Korea, South Sudan, Spain, Sri Lanka, Sudan, '
      'Suriname, Sweden, Switzerland, Syria, Taiwan, Tajikistan, Tanzania, Thailand, Timor-Leste, Togo, Tonga, '
      'Trinidad and Tobago, Tunisia, Turkey, Turkmenistan, Tuvalu, Uganda, Ukraine, United Arab Emirates, '
      'United Kingdom, United States, Uruguay, Uzbekistan, Vanuatu, Vatican City, Venezuela, Vietnam, Yemen, '
      'Zambia, Zimbabwe';

  static const Map<String, String> _indiaDistricts = {
    'Andaman and Nicobar Islands': 'Nicobar, North and Middle Andaman, South Andaman',
    'Andhra Pradesh':
        'Alluri Sitharama Raju, Anakapalli, Anantapuramu, Annamayya, Bapatla, Chittoor, Dr. B.R. Ambedkar Konaseema, '
        'East Godavari, Eluru, Guntur, Kakinada, Krishna, Kurnool, Nandyal, NTR, Palnadu, Parvathipuram Manyam, '
        'Prakasam, Sri Potti Sriramulu Nellore, Sri Sathya Sai, Srikakulam, Tirupati, Visakhapatnam, Vizianagaram, '
        'West Godavari, YSR Kadapa',
    'Arunachal Pradesh':
        'Anjaw, Changlang, Dibang Valley, East Kameng, East Siang, Kamle, Kra Daadi, Kurung Kumey, Lepa Rada, Lohit, '
        'Longding, Lower Dibang Valley, Lower Siang, Lower Subansiri, Namsai, Pakke-Kessang, Papum Pare, Shi Yomi, '
        'Siang, Tawang, Tirap, Upper Siang, Upper Subansiri, West Kameng, West Siang',
    'Assam':
        'Baksa, Barpeta, Biswanath, Bongaigaon, Cachar, Charaideo, Chirang, Darrang, Dhemaji, Dhubri, Dibrugarh, '
        'Dima Hasao, Goalpara, Golaghat, Hailakandi, Hojai, Jorhat, Kamrup, Kamrup Metropolitan, Karbi Anglong, '
        'Karimganj, Kokrajhar, Lakhimpur, Majuli, Morigaon, Nagaon, Nalbari, Sivasagar, Sonitpur, '
        'South Salmara-Mankachar, Tinsukia, Udalguri, West Karbi Anglong',
    'Bihar':
        'Araria, Arwal, Aurangabad, Banka, Begusarai, Bhagalpur, Bhojpur, Buxar, Darbhanga, East Champaran, Gaya, '
        'Gopalganj, Jamui, Jehanabad, Kaimur, Katihar, Khagaria, Kishanganj, Lakhisarai, Madhepura, Madhubani, '
        'Munger, Muzaffarpur, Nalanda, Nawada, Patna, Purnia, Rohtas, Saharsa, Samastipur, Saran, Sheikhpura, '
        'Sheohar, Sitamarhi, Siwan, Supaul, Vaishali, West Champaran',
    'Chandigarh': 'Chandigarh',
    'Chhattisgarh':
        'Balod, Baloda Bazar, Balrampur, Bastar, Bemetara, Bijapur, Bilaspur, Dantewada, Dhamtari, Durg, Gariaband, '
        'Gaurela-Pendra-Marwahi, Janjgir-Champa, Jashpur, Kabirdham, Kanker, Khairagarh-Chhuikhadan-Gandai, '
        'Kondagaon, Korba, Koriya, Mahasamund, Manendragarh-Chirmiri-Bharatpur, Mohla-Manpur-Ambagarh Chowki, '
        'Mungeli, Narayanpur, Raigarh, Raipur, Rajnandgaon, Sakti, Sarangarh-Bilaigarh, Sukma, Surajpur, Surguja',
    'Dadra and Nagar Haveli and Daman and Diu': 'Dadra and Nagar Haveli, Daman, Diu',
    'Delhi':
        'Central Delhi, East Delhi, New Delhi, North Delhi, North East Delhi, North West Delhi, Shahdara, South Delhi, '
        'South East Delhi, South West Delhi, West Delhi',
    'Goa': 'North Goa, South Goa',
    'Gujarat':
        'Ahmedabad, Amreli, Anand, Aravalli, Banaskantha, Bharuch, Bhavnagar, Botad, Chhota Udaipur, Dahod, Dang, '
        'Devbhoomi Dwarka, Gandhinagar, Gir Somnath, Jamnagar, Junagadh, Kheda, Kutch, Mahisagar, Mehsana, Morbi, '
        'Narmada, Navsari, Panchmahal, Patan, Porbandar, Rajkot, Sabarkantha, Surat, Surendranagar, Tapi, Vadodara, '
        'Valsad',
    'Haryana':
        'Ambala, Bhiwani, Charkhi Dadri, Faridabad, Fatehabad, Gurugram, Hisar, Jhajjar, Jind, Kaithal, Karnal, '
        'Kurukshetra, Mahendragarh, Nuh, Palwal, Panchkula, Panipat, Rewari, Rohtak, Sirsa, Sonipat, Yamunanagar',
    'Himachal Pradesh':
        'Bilaspur, Chamba, Hamirpur, Kangra, Kinnaur, Kullu, Lahaul and Spiti, Mandi, Shimla, Sirmaur, Solan, Una',
    'Jammu and Kashmir':
        'Anantnag, Bandipora, Baramulla, Budgam, Doda, Ganderbal, Jammu, Kathua, Kishtwar, Kulgam, Kupwara, Poonch, '
        'Pulwama, Rajouri, Ramban, Reasi, Samba, Shopian, Srinagar, Udhampur',
    'Jharkhand':
        'Bokaro, Chatra, Deoghar, Dhanbad, Dumka, East Singhbhum, Garhwa, Giridih, Godda, Gumla, Hazaribagh, Jamtara, '
        'Khunti, Koderma, Latehar, Lohardaga, Pakur, Palamu, Ramgarh, Ranchi, Sahebganj, Seraikela Kharsawan, '
        'Simdega, West Singhbhum',
    'Karnataka':
        'Bagalkot, Ballari, Belagavi, Bengaluru Rural, Bengaluru Urban, Bidar, Chamarajanagar, Chikkaballapur, '
        'Chikkamagaluru, Chitradurga, Dakshina Kannada, Davanagere, Dharwad, Gadag, Hassan, Haveri, Kalaburagi, '
        'Kodagu, Kolar, Koppal, Mandya, Mysuru, Raichur, Ramanagara, Shivamogga, Tumakuru, Udupi, Uttara Kannada, '
        'Vijayanagara, Vijayapura, Yadgir',
    'Kerala':
        'Alappuzha, Ernakulam, Idukki, Kannur, Kasaragod, Kollam, Kottayam, Kozhikode, Malappuram, Palakkad, '
        'Pathanamthitta, Thiruvananthapuram, Thrissur, Wayanad',
    'Ladakh': 'Kargil, Leh',
    'Lakshadweep': 'Lakshadweep',
    'Madhya Pradesh':
        'Agar Malwa, Alirajpur, Anuppur, Ashoknagar, Balaghat, Barwani, Betul, Bhind, Bhopal, Burhanpur, Chhatarpur, '
        'Chhindwara, Damoh, Datia, Dewas, Dhar, Dindori, Guna, Gwalior, Harda, Indore, Jabalpur, Jhabua, Katni, '
        'Khandwa, Khargone, Maihar, Mandla, Mandsaur, Mauganj, Morena, Narmadapuram, Narsinghpur, Neemuch, Niwari, '
        'Pandhurna, Panna, Raisen, Rajgarh, Ratlam, Rewa, Sagar, Satna, Sehore, Seoni, Shahdol, Shajapur, Sheopur, '
        'Shivpuri, Sidhi, Singrauli, Tikamgarh, Ujjain, Umaria, Vidisha',
    'Maharashtra':
        'Ahilyanagar, Akola, Amravati, Beed, Bhandara, Buldhana, Chandrapur, Chhatrapati Sambhajinagar, Dharashiv, '
        'Dhule, Gadchiroli, Gondia, Hingoli, Jalgaon, Jalna, Kolhapur, Latur, Mumbai City, Mumbai Suburban, Nagpur, '
        'Nanded, Nandurbar, Nashik, Palghar, Parbhani, Pune, Raigad, Ratnagiri, Sangli, Satara, Sindhudurg, Solapur, '
        'Thane, Wardha, Washim, Yavatmal',
    'Manipur':
        'Bishnupur, Chandel, Churachandpur, Imphal East, Imphal West, Jiribam, Kakching, Kamjong, Kangpokpi, Noney, '
        'Pherzawl, Senapati, Tamenglong, Tengnoupal, Thoubal, Ukhrul',
    'Meghalaya':
        'East Garo Hills, East Jaintia Hills, East Khasi Hills, Eastern West Khasi Hills, North Garo Hills, Ri Bhoi, '
        'South Garo Hills, South West Garo Hills, South West Khasi Hills, West Garo Hills, West Jaintia Hills, '
        'West Khasi Hills',
    'Mizoram': 'Aizawl, Champhai, Hnahthial, Khawzawl, Kolasib, Lawngtlai, Lunglei, Mamit, Saitual, Serchhip, Siaha',
    'Nagaland':
        'Chumoukedima, Dimapur, Kiphire, Kohima, Longleng, Mokokchung, Mon, Niuland, Noklak, Peren, Phek, Shamator, '
        'Tseminyu, Tuensang, Wokha, Zunheboto',
    'Odisha':
        'Angul, Balangir, Balasore, Bargarh, Bhadrak, Boudh, Cuttack, Deogarh, Dhenkanal, Gajapati, Ganjam, '
        'Jagatsinghpur, Jajpur, Jharsuguda, Kalahandi, Kandhamal, Kendrapara, Kendujhar, Khordha, Koraput, Malkangiri, '
        'Mayurbhanj, Nabarangpur, Nayagarh, Nuapada, Puri, Rayagada, Sambalpur, Subarnapur, Sundargarh',
    'Puducherry': 'Karaikal, Mahe, Puducherry, Yanam',
    'Punjab':
        'Amritsar, Barnala, Bathinda, Faridkot, Fatehgarh Sahib, Fazilka, Ferozepur, Gurdaspur, Hoshiarpur, Jalandhar, '
        'Kapurthala, Ludhiana, Malerkotla, Mansa, Moga, Pathankot, Patiala, Rupnagar, Sahibzada Ajit Singh Nagar, '
        'Sangrur, Shaheed Bhagat Singh Nagar, Sri Muktsar Sahib, Tarn Taran',
    'Rajasthan':
        'Ajmer, Alwar, Banswara, Baran, Barmer, Bharatpur, Bhilwara, Bikaner, Bundi, Chittorgarh, Churu, Dausa, '
        'Dholpur, Dungarpur, Hanumangarh, Jaipur, Jaisalmer, Jalore, Jhalawar, Jhunjhunu, Jodhpur, Karauli, Kota, '
        'Nagaur, Pali, Pratapgarh, Rajsamand, Sawai Madhopur, Sikar, Sirohi, Sri Ganganagar, Tonk, Udaipur',
    'Sikkim': 'Gangtok, Gyalshing, Mangan, Namchi, Pakyong, Soreng',
    'Tamil Nadu':
        'Ariyalur, Chengalpattu, Chennai, Coimbatore, Cuddalore, Dharmapuri, Dindigul, Erode, Kallakurichi, '
        'Kancheepuram, Kanniyakumari, Karur, Krishnagiri, Madurai, Mayiladuthurai, Nagapattinam, Namakkal, Nilgiris, '
        'Perambalur, Pudukkottai, Ramanathapuram, Ranipet, Salem, Sivaganga, Tenkasi, Thanjavur, Theni, Thoothukudi, '
        'Tiruchirappalli, Tirunelveli, Tirupathur, Tiruppur, Tiruvallur, Tiruvannamalai, Tiruvarur, Vellore, '
        'Viluppuram, Virudhunagar',
    'Telangana':
        'Adilabad, Bhadradri Kothagudem, Hanumakonda, Hyderabad, Jagtial, Jangaon, Jayashankar Bhupalpally, '
        'Jogulamba Gadwal, Kamareddy, Karimnagar, Khammam, Kumuram Bheem Asifabad, Mahabubabad, Mahabubnagar, '
        'Mancherial, Medak, Medchal-Malkajgiri, Mulugu, Nagarkurnool, Nalgonda, Narayanpet, Nirmal, Nizamabad, '
        'Peddapalli, Rajanna Sircilla, Rangareddy, Sangareddy, Siddipet, Suryapet, Vikarabad, Wanaparthy, Warangal, '
        'Yadadri Bhuvanagiri',
    'Tripura': 'Dhalai, Gomati, Khowai, North Tripura, Sepahijala, South Tripura, Unakoti, West Tripura',
    'Uttar Pradesh':
        'Agra, Aligarh, Ambedkar Nagar, Amethi, Amroha, Auraiya, Ayodhya, Azamgarh, Baghpat, Bahraich, Ballia, '
        'Balrampur, Banda, Barabanki, Bareilly, Basti, Bhadohi, Bijnor, Budaun, Bulandshahr, Chandauli, Chitrakoot, '
        'Deoria, Etah, Etawah, Farrukhabad, Fatehpur, Firozabad, Gautam Buddha Nagar, Ghaziabad, Ghazipur, Gonda, '
        'Gorakhpur, Hamirpur, Hapur, Hardoi, Hathras, Jalaun, Jaunpur, Jhansi, Kannauj, Kanpur Dehat, Kanpur Nagar, '
        'Kasganj, Kaushambi, Kushinagar, Lakhimpur Kheri, Lalitpur, Lucknow, Maharajganj, Mahoba, Mainpuri, Mathura, '
        'Mau, Meerut, Mirzapur, Moradabad, Muzaffarnagar, Pilibhit, Pratapgarh, Prayagraj, Raebareli, Rampur, '
        'Saharanpur, Sambhal, Sant Kabir Nagar, Shahjahanpur, Shamli, Shravasti, Siddharthnagar, Sitapur, Sonbhadra, '
        'Sultanpur, Unnao, Varanasi',
    'Uttarakhand':
        'Almora, Bageshwar, Chamoli, Champawat, Dehradun, Haridwar, Nainital, Pauri Garhwal, Pithoragarh, Rudraprayag, '
        'Tehri Garhwal, Udham Singh Nagar, Uttarkashi',
    'West Bengal':
        'Alipurduar, Bankura, Birbhum, Cooch Behar, Dakshin Dinajpur, Darjeeling, Hooghly, Howrah, Jalpaiguri, '
        'Jhargram, Kalimpong, Kolkata, Malda, Murshidabad, Nadia, North 24 Parganas, Paschim Bardhaman, '
        'Paschim Medinipur, Purba Bardhaman, Purba Medinipur, Purulia, South 24 Parganas, Uttar Dinajpur',
  };
}
