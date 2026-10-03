// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $BanksTable extends Banks with TableInfo<$BanksTable, Bank> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BanksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _descriptionMeta = const VerificationMeta(
    'description',
  );
  @override
  late final GeneratedColumn<String> description = GeneratedColumn<String>(
    'description',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _questionCountMeta = const VerificationMeta(
    'questionCount',
  );
  @override
  late final GeneratedColumn<int> questionCount = GeneratedColumn<int>(
    'question_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [id, title, description, questionCount];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'banks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Bank> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('description')) {
      context.handle(
        _descriptionMeta,
        description.isAcceptableOrUnknown(
          data['description']!,
          _descriptionMeta,
        ),
      );
    }
    if (data.containsKey('question_count')) {
      context.handle(
        _questionCountMeta,
        questionCount.isAcceptableOrUnknown(
          data['question_count']!,
          _questionCountMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Bank map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Bank(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      description: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}description'],
      )!,
      questionCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}question_count'],
      )!,
    );
  }

  @override
  $BanksTable createAlias(String alias) {
    return $BanksTable(attachedDatabase, alias);
  }
}

class Bank extends DataClass implements Insertable<Bank> {
  final String id;
  final String title;
  final String description;
  final int questionCount;
  const Bank({
    required this.id,
    required this.title,
    required this.description,
    required this.questionCount,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['description'] = Variable<String>(description);
    map['question_count'] = Variable<int>(questionCount);
    return map;
  }

  BanksCompanion toCompanion(bool nullToAbsent) {
    return BanksCompanion(
      id: Value(id),
      title: Value(title),
      description: Value(description),
      questionCount: Value(questionCount),
    );
  }

  factory Bank.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Bank(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      description: serializer.fromJson<String>(json['description']),
      questionCount: serializer.fromJson<int>(json['questionCount']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'description': serializer.toJson<String>(description),
      'questionCount': serializer.toJson<int>(questionCount),
    };
  }

  Bank copyWith({
    String? id,
    String? title,
    String? description,
    int? questionCount,
  }) => Bank(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    questionCount: questionCount ?? this.questionCount,
  );
  Bank copyWithCompanion(BanksCompanion data) {
    return Bank(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      description: data.description.present
          ? data.description.value
          : this.description,
      questionCount: data.questionCount.present
          ? data.questionCount.value
          : this.questionCount,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Bank(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('questionCount: $questionCount')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, description, questionCount);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Bank &&
          other.id == this.id &&
          other.title == this.title &&
          other.description == this.description &&
          other.questionCount == this.questionCount);
}

class BanksCompanion extends UpdateCompanion<Bank> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> description;
  final Value<int> questionCount;
  final Value<int> rowid;
  const BanksCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.description = const Value.absent(),
    this.questionCount = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BanksCompanion.insert({
    required String id,
    required String title,
    this.description = const Value.absent(),
    this.questionCount = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title);
  static Insertable<Bank> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? description,
    Expression<int>? questionCount,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (questionCount != null) 'question_count': questionCount,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BanksCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? description,
    Value<int>? questionCount,
    Value<int>? rowid,
  }) {
    return BanksCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      questionCount: questionCount ?? this.questionCount,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (description.present) {
      map['description'] = Variable<String>(description.value);
    }
    if (questionCount.present) {
      map['question_count'] = Variable<int>(questionCount.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BanksCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('description: $description, ')
          ..write('questionCount: $questionCount, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $QuestionsTable extends Questions
    with TableInfo<$QuestionsTable, Question> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuestionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bankIdMeta = const VerificationMeta('bankId');
  @override
  late final GeneratedColumn<String> bankId = GeneratedColumn<String>(
    'bank_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stemMeta = const VerificationMeta('stem');
  @override
  late final GeneratedColumn<String> stem = GeneratedColumn<String>(
    'stem',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _optionsJsonMeta = const VerificationMeta(
    'optionsJson',
  );
  @override
  late final GeneratedColumn<String> optionsJson = GeneratedColumn<String>(
    'options_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _answerJsonMeta = const VerificationMeta(
    'answerJson',
  );
  @override
  late final GeneratedColumn<String> answerJson = GeneratedColumn<String>(
    'answer_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _explanationMeta = const VerificationMeta(
    'explanation',
  );
  @override
  late final GeneratedColumn<String> explanation = GeneratedColumn<String>(
    'explanation',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _difficultyMeta = const VerificationMeta(
    'difficulty',
  );
  @override
  late final GeneratedColumn<int> difficulty = GeneratedColumn<int>(
    'difficulty',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(3),
  );
  static const VerificationMeta _tagsJsonMeta = const VerificationMeta(
    'tagsJson',
  );
  @override
  late final GeneratedColumn<String> tagsJson = GeneratedColumn<String>(
    'tags_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _sourceQuoteMeta = const VerificationMeta(
    'sourceQuote',
  );
  @override
  late final GeneratedColumn<String> sourceQuote = GeneratedColumn<String>(
    'source_quote',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _syncSeqMeta = const VerificationMeta(
    'syncSeq',
  );
  @override
  late final GeneratedColumn<int> syncSeq = GeneratedColumn<int>(
    'sync_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hiddenMeta = const VerificationMeta('hidden');
  @override
  late final GeneratedColumn<bool> hidden = GeneratedColumn<bool>(
    'hidden',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    bankId,
    type,
    stem,
    optionsJson,
    answerJson,
    explanation,
    difficulty,
    tagsJson,
    sourceQuote,
    syncSeq,
    hidden,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'questions';
  @override
  VerificationContext validateIntegrity(
    Insertable<Question> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('bank_id')) {
      context.handle(
        _bankIdMeta,
        bankId.isAcceptableOrUnknown(data['bank_id']!, _bankIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bankIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('stem')) {
      context.handle(
        _stemMeta,
        stem.isAcceptableOrUnknown(data['stem']!, _stemMeta),
      );
    } else if (isInserting) {
      context.missing(_stemMeta);
    }
    if (data.containsKey('options_json')) {
      context.handle(
        _optionsJsonMeta,
        optionsJson.isAcceptableOrUnknown(
          data['options_json']!,
          _optionsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_optionsJsonMeta);
    }
    if (data.containsKey('answer_json')) {
      context.handle(
        _answerJsonMeta,
        answerJson.isAcceptableOrUnknown(data['answer_json']!, _answerJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_answerJsonMeta);
    }
    if (data.containsKey('explanation')) {
      context.handle(
        _explanationMeta,
        explanation.isAcceptableOrUnknown(
          data['explanation']!,
          _explanationMeta,
        ),
      );
    }
    if (data.containsKey('difficulty')) {
      context.handle(
        _difficultyMeta,
        difficulty.isAcceptableOrUnknown(data['difficulty']!, _difficultyMeta),
      );
    }
    if (data.containsKey('tags_json')) {
      context.handle(
        _tagsJsonMeta,
        tagsJson.isAcceptableOrUnknown(data['tags_json']!, _tagsJsonMeta),
      );
    }
    if (data.containsKey('source_quote')) {
      context.handle(
        _sourceQuoteMeta,
        sourceQuote.isAcceptableOrUnknown(
          data['source_quote']!,
          _sourceQuoteMeta,
        ),
      );
    }
    if (data.containsKey('sync_seq')) {
      context.handle(
        _syncSeqMeta,
        syncSeq.isAcceptableOrUnknown(data['sync_seq']!, _syncSeqMeta),
      );
    } else if (isInserting) {
      context.missing(_syncSeqMeta);
    }
    if (data.containsKey('hidden')) {
      context.handle(
        _hiddenMeta,
        hidden.isAcceptableOrUnknown(data['hidden']!, _hiddenMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Question map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Question(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      bankId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bank_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      stem: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stem'],
      )!,
      optionsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}options_json'],
      )!,
      answerJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}answer_json'],
      )!,
      explanation: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}explanation'],
      )!,
      difficulty: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}difficulty'],
      )!,
      tagsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags_json'],
      )!,
      sourceQuote: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_quote'],
      )!,
      syncSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sync_seq'],
      )!,
      hidden: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden'],
      )!,
    );
  }

  @override
  $QuestionsTable createAlias(String alias) {
    return $QuestionsTable(attachedDatabase, alias);
  }
}

class Question extends DataClass implements Insertable<Question> {
  final String id;
  final String bankId;
  final String type;
  final String stem;
  final String optionsJson;
  final String answerJson;
  final String explanation;
  final int difficulty;
  final String tagsJson;
  final String sourceQuote;
  final int syncSeq;
  final bool hidden;
  const Question({
    required this.id,
    required this.bankId,
    required this.type,
    required this.stem,
    required this.optionsJson,
    required this.answerJson,
    required this.explanation,
    required this.difficulty,
    required this.tagsJson,
    required this.sourceQuote,
    required this.syncSeq,
    required this.hidden,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['bank_id'] = Variable<String>(bankId);
    map['type'] = Variable<String>(type);
    map['stem'] = Variable<String>(stem);
    map['options_json'] = Variable<String>(optionsJson);
    map['answer_json'] = Variable<String>(answerJson);
    map['explanation'] = Variable<String>(explanation);
    map['difficulty'] = Variable<int>(difficulty);
    map['tags_json'] = Variable<String>(tagsJson);
    map['source_quote'] = Variable<String>(sourceQuote);
    map['sync_seq'] = Variable<int>(syncSeq);
    map['hidden'] = Variable<bool>(hidden);
    return map;
  }

  QuestionsCompanion toCompanion(bool nullToAbsent) {
    return QuestionsCompanion(
      id: Value(id),
      bankId: Value(bankId),
      type: Value(type),
      stem: Value(stem),
      optionsJson: Value(optionsJson),
      answerJson: Value(answerJson),
      explanation: Value(explanation),
      difficulty: Value(difficulty),
      tagsJson: Value(tagsJson),
      sourceQuote: Value(sourceQuote),
      syncSeq: Value(syncSeq),
      hidden: Value(hidden),
    );
  }

  factory Question.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Question(
      id: serializer.fromJson<String>(json['id']),
      bankId: serializer.fromJson<String>(json['bankId']),
      type: serializer.fromJson<String>(json['type']),
      stem: serializer.fromJson<String>(json['stem']),
      optionsJson: serializer.fromJson<String>(json['optionsJson']),
      answerJson: serializer.fromJson<String>(json['answerJson']),
      explanation: serializer.fromJson<String>(json['explanation']),
      difficulty: serializer.fromJson<int>(json['difficulty']),
      tagsJson: serializer.fromJson<String>(json['tagsJson']),
      sourceQuote: serializer.fromJson<String>(json['sourceQuote']),
      syncSeq: serializer.fromJson<int>(json['syncSeq']),
      hidden: serializer.fromJson<bool>(json['hidden']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'bankId': serializer.toJson<String>(bankId),
      'type': serializer.toJson<String>(type),
      'stem': serializer.toJson<String>(stem),
      'optionsJson': serializer.toJson<String>(optionsJson),
      'answerJson': serializer.toJson<String>(answerJson),
      'explanation': serializer.toJson<String>(explanation),
      'difficulty': serializer.toJson<int>(difficulty),
      'tagsJson': serializer.toJson<String>(tagsJson),
      'sourceQuote': serializer.toJson<String>(sourceQuote),
      'syncSeq': serializer.toJson<int>(syncSeq),
      'hidden': serializer.toJson<bool>(hidden),
    };
  }

  Question copyWith({
    String? id,
    String? bankId,
    String? type,
    String? stem,
    String? optionsJson,
    String? answerJson,
    String? explanation,
    int? difficulty,
    String? tagsJson,
    String? sourceQuote,
    int? syncSeq,
    bool? hidden,
  }) => Question(
    id: id ?? this.id,
    bankId: bankId ?? this.bankId,
    type: type ?? this.type,
    stem: stem ?? this.stem,
    optionsJson: optionsJson ?? this.optionsJson,
    answerJson: answerJson ?? this.answerJson,
    explanation: explanation ?? this.explanation,
    difficulty: difficulty ?? this.difficulty,
    tagsJson: tagsJson ?? this.tagsJson,
    sourceQuote: sourceQuote ?? this.sourceQuote,
    syncSeq: syncSeq ?? this.syncSeq,
    hidden: hidden ?? this.hidden,
  );
  Question copyWithCompanion(QuestionsCompanion data) {
    return Question(
      id: data.id.present ? data.id.value : this.id,
      bankId: data.bankId.present ? data.bankId.value : this.bankId,
      type: data.type.present ? data.type.value : this.type,
      stem: data.stem.present ? data.stem.value : this.stem,
      optionsJson: data.optionsJson.present
          ? data.optionsJson.value
          : this.optionsJson,
      answerJson: data.answerJson.present
          ? data.answerJson.value
          : this.answerJson,
      explanation: data.explanation.present
          ? data.explanation.value
          : this.explanation,
      difficulty: data.difficulty.present
          ? data.difficulty.value
          : this.difficulty,
      tagsJson: data.tagsJson.present ? data.tagsJson.value : this.tagsJson,
      sourceQuote: data.sourceQuote.present
          ? data.sourceQuote.value
          : this.sourceQuote,
      syncSeq: data.syncSeq.present ? data.syncSeq.value : this.syncSeq,
      hidden: data.hidden.present ? data.hidden.value : this.hidden,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Question(')
          ..write('id: $id, ')
          ..write('bankId: $bankId, ')
          ..write('type: $type, ')
          ..write('stem: $stem, ')
          ..write('optionsJson: $optionsJson, ')
          ..write('answerJson: $answerJson, ')
          ..write('explanation: $explanation, ')
          ..write('difficulty: $difficulty, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('sourceQuote: $sourceQuote, ')
          ..write('syncSeq: $syncSeq, ')
          ..write('hidden: $hidden')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    bankId,
    type,
    stem,
    optionsJson,
    answerJson,
    explanation,
    difficulty,
    tagsJson,
    sourceQuote,
    syncSeq,
    hidden,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Question &&
          other.id == this.id &&
          other.bankId == this.bankId &&
          other.type == this.type &&
          other.stem == this.stem &&
          other.optionsJson == this.optionsJson &&
          other.answerJson == this.answerJson &&
          other.explanation == this.explanation &&
          other.difficulty == this.difficulty &&
          other.tagsJson == this.tagsJson &&
          other.sourceQuote == this.sourceQuote &&
          other.syncSeq == this.syncSeq &&
          other.hidden == this.hidden);
}

class QuestionsCompanion extends UpdateCompanion<Question> {
  final Value<String> id;
  final Value<String> bankId;
  final Value<String> type;
  final Value<String> stem;
  final Value<String> optionsJson;
  final Value<String> answerJson;
  final Value<String> explanation;
  final Value<int> difficulty;
  final Value<String> tagsJson;
  final Value<String> sourceQuote;
  final Value<int> syncSeq;
  final Value<bool> hidden;
  final Value<int> rowid;
  const QuestionsCompanion({
    this.id = const Value.absent(),
    this.bankId = const Value.absent(),
    this.type = const Value.absent(),
    this.stem = const Value.absent(),
    this.optionsJson = const Value.absent(),
    this.answerJson = const Value.absent(),
    this.explanation = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.sourceQuote = const Value.absent(),
    this.syncSeq = const Value.absent(),
    this.hidden = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  QuestionsCompanion.insert({
    required String id,
    required String bankId,
    required String type,
    required String stem,
    required String optionsJson,
    required String answerJson,
    this.explanation = const Value.absent(),
    this.difficulty = const Value.absent(),
    this.tagsJson = const Value.absent(),
    this.sourceQuote = const Value.absent(),
    required int syncSeq,
    this.hidden = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       bankId = Value(bankId),
       type = Value(type),
       stem = Value(stem),
       optionsJson = Value(optionsJson),
       answerJson = Value(answerJson),
       syncSeq = Value(syncSeq);
  static Insertable<Question> custom({
    Expression<String>? id,
    Expression<String>? bankId,
    Expression<String>? type,
    Expression<String>? stem,
    Expression<String>? optionsJson,
    Expression<String>? answerJson,
    Expression<String>? explanation,
    Expression<int>? difficulty,
    Expression<String>? tagsJson,
    Expression<String>? sourceQuote,
    Expression<int>? syncSeq,
    Expression<bool>? hidden,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bankId != null) 'bank_id': bankId,
      if (type != null) 'type': type,
      if (stem != null) 'stem': stem,
      if (optionsJson != null) 'options_json': optionsJson,
      if (answerJson != null) 'answer_json': answerJson,
      if (explanation != null) 'explanation': explanation,
      if (difficulty != null) 'difficulty': difficulty,
      if (tagsJson != null) 'tags_json': tagsJson,
      if (sourceQuote != null) 'source_quote': sourceQuote,
      if (syncSeq != null) 'sync_seq': syncSeq,
      if (hidden != null) 'hidden': hidden,
      if (rowid != null) 'rowid': rowid,
    });
  }

  QuestionsCompanion copyWith({
    Value<String>? id,
    Value<String>? bankId,
    Value<String>? type,
    Value<String>? stem,
    Value<String>? optionsJson,
    Value<String>? answerJson,
    Value<String>? explanation,
    Value<int>? difficulty,
    Value<String>? tagsJson,
    Value<String>? sourceQuote,
    Value<int>? syncSeq,
    Value<bool>? hidden,
    Value<int>? rowid,
  }) {
    return QuestionsCompanion(
      id: id ?? this.id,
      bankId: bankId ?? this.bankId,
      type: type ?? this.type,
      stem: stem ?? this.stem,
      optionsJson: optionsJson ?? this.optionsJson,
      answerJson: answerJson ?? this.answerJson,
      explanation: explanation ?? this.explanation,
      difficulty: difficulty ?? this.difficulty,
      tagsJson: tagsJson ?? this.tagsJson,
      sourceQuote: sourceQuote ?? this.sourceQuote,
      syncSeq: syncSeq ?? this.syncSeq,
      hidden: hidden ?? this.hidden,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (bankId.present) {
      map['bank_id'] = Variable<String>(bankId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (stem.present) {
      map['stem'] = Variable<String>(stem.value);
    }
    if (optionsJson.present) {
      map['options_json'] = Variable<String>(optionsJson.value);
    }
    if (answerJson.present) {
      map['answer_json'] = Variable<String>(answerJson.value);
    }
    if (explanation.present) {
      map['explanation'] = Variable<String>(explanation.value);
    }
    if (difficulty.present) {
      map['difficulty'] = Variable<int>(difficulty.value);
    }
    if (tagsJson.present) {
      map['tags_json'] = Variable<String>(tagsJson.value);
    }
    if (sourceQuote.present) {
      map['source_quote'] = Variable<String>(sourceQuote.value);
    }
    if (syncSeq.present) {
      map['sync_seq'] = Variable<int>(syncSeq.value);
    }
    if (hidden.present) {
      map['hidden'] = Variable<bool>(hidden.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuestionsCompanion(')
          ..write('id: $id, ')
          ..write('bankId: $bankId, ')
          ..write('type: $type, ')
          ..write('stem: $stem, ')
          ..write('optionsJson: $optionsJson, ')
          ..write('answerJson: $answerJson, ')
          ..write('explanation: $explanation, ')
          ..write('difficulty: $difficulty, ')
          ..write('tagsJson: $tagsJson, ')
          ..write('sourceQuote: $sourceQuote, ')
          ..write('syncSeq: $syncSeq, ')
          ..write('hidden: $hidden, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AttemptsTable extends Attempts with TableInfo<$AttemptsTable, Attempt> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AttemptsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _answerJsonMeta = const VerificationMeta(
    'answerJson',
  );
  @override
  late final GeneratedColumn<String> answerJson = GeneratedColumn<String>(
    'answer_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isCorrectMeta = const VerificationMeta(
    'isCorrect',
  );
  @override
  late final GeneratedColumn<bool> isCorrect = GeneratedColumn<bool>(
    'is_correct',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_correct" IN (0, 1))',
    ),
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _answeredAtMeta = const VerificationMeta(
    'answeredAt',
  );
  @override
  late final GeneratedColumn<int> answeredAt = GeneratedColumn<int>(
    'answered_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncedMeta = const VerificationMeta('synced');
  @override
  late final GeneratedColumn<bool> synced = GeneratedColumn<bool>(
    'synced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("synced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    questionId,
    deviceId,
    answerJson,
    isCorrect,
    durationMs,
    answeredAt,
    synced,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'attempts';
  @override
  VerificationContext validateIntegrity(
    Insertable<Attempt> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_questionIdMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_deviceIdMeta);
    }
    if (data.containsKey('answer_json')) {
      context.handle(
        _answerJsonMeta,
        answerJson.isAcceptableOrUnknown(data['answer_json']!, _answerJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_answerJsonMeta);
    }
    if (data.containsKey('is_correct')) {
      context.handle(
        _isCorrectMeta,
        isCorrect.isAcceptableOrUnknown(data['is_correct']!, _isCorrectMeta),
      );
    } else if (isInserting) {
      context.missing(_isCorrectMeta);
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('answered_at')) {
      context.handle(
        _answeredAtMeta,
        answeredAt.isAcceptableOrUnknown(data['answered_at']!, _answeredAtMeta),
      );
    } else if (isInserting) {
      context.missing(_answeredAtMeta);
    }
    if (data.containsKey('synced')) {
      context.handle(
        _syncedMeta,
        synced.isAcceptableOrUnknown(data['synced']!, _syncedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Attempt map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Attempt(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      answerJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}answer_json'],
      )!,
      isCorrect: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_correct'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      answeredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}answered_at'],
      )!,
      synced: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}synced'],
      )!,
    );
  }

  @override
  $AttemptsTable createAlias(String alias) {
    return $AttemptsTable(attachedDatabase, alias);
  }
}

class Attempt extends DataClass implements Insertable<Attempt> {
  final String id;
  final String questionId;
  final String deviceId;
  final String answerJson;
  final bool isCorrect;
  final int? durationMs;
  final int answeredAt;
  final bool synced;
  const Attempt({
    required this.id,
    required this.questionId,
    required this.deviceId,
    required this.answerJson,
    required this.isCorrect,
    this.durationMs,
    required this.answeredAt,
    required this.synced,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['question_id'] = Variable<String>(questionId);
    map['device_id'] = Variable<String>(deviceId);
    map['answer_json'] = Variable<String>(answerJson);
    map['is_correct'] = Variable<bool>(isCorrect);
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    map['answered_at'] = Variable<int>(answeredAt);
    map['synced'] = Variable<bool>(synced);
    return map;
  }

  AttemptsCompanion toCompanion(bool nullToAbsent) {
    return AttemptsCompanion(
      id: Value(id),
      questionId: Value(questionId),
      deviceId: Value(deviceId),
      answerJson: Value(answerJson),
      isCorrect: Value(isCorrect),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      answeredAt: Value(answeredAt),
      synced: Value(synced),
    );
  }

  factory Attempt.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Attempt(
      id: serializer.fromJson<String>(json['id']),
      questionId: serializer.fromJson<String>(json['questionId']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      answerJson: serializer.fromJson<String>(json['answerJson']),
      isCorrect: serializer.fromJson<bool>(json['isCorrect']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      answeredAt: serializer.fromJson<int>(json['answeredAt']),
      synced: serializer.fromJson<bool>(json['synced']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'questionId': serializer.toJson<String>(questionId),
      'deviceId': serializer.toJson<String>(deviceId),
      'answerJson': serializer.toJson<String>(answerJson),
      'isCorrect': serializer.toJson<bool>(isCorrect),
      'durationMs': serializer.toJson<int?>(durationMs),
      'answeredAt': serializer.toJson<int>(answeredAt),
      'synced': serializer.toJson<bool>(synced),
    };
  }

  Attempt copyWith({
    String? id,
    String? questionId,
    String? deviceId,
    String? answerJson,
    bool? isCorrect,
    Value<int?> durationMs = const Value.absent(),
    int? answeredAt,
    bool? synced,
  }) => Attempt(
    id: id ?? this.id,
    questionId: questionId ?? this.questionId,
    deviceId: deviceId ?? this.deviceId,
    answerJson: answerJson ?? this.answerJson,
    isCorrect: isCorrect ?? this.isCorrect,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    answeredAt: answeredAt ?? this.answeredAt,
    synced: synced ?? this.synced,
  );
  Attempt copyWithCompanion(AttemptsCompanion data) {
    return Attempt(
      id: data.id.present ? data.id.value : this.id,
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      answerJson: data.answerJson.present
          ? data.answerJson.value
          : this.answerJson,
      isCorrect: data.isCorrect.present ? data.isCorrect.value : this.isCorrect,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      answeredAt: data.answeredAt.present
          ? data.answeredAt.value
          : this.answeredAt,
      synced: data.synced.present ? data.synced.value : this.synced,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Attempt(')
          ..write('id: $id, ')
          ..write('questionId: $questionId, ')
          ..write('deviceId: $deviceId, ')
          ..write('answerJson: $answerJson, ')
          ..write('isCorrect: $isCorrect, ')
          ..write('durationMs: $durationMs, ')
          ..write('answeredAt: $answeredAt, ')
          ..write('synced: $synced')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    questionId,
    deviceId,
    answerJson,
    isCorrect,
    durationMs,
    answeredAt,
    synced,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Attempt &&
          other.id == this.id &&
          other.questionId == this.questionId &&
          other.deviceId == this.deviceId &&
          other.answerJson == this.answerJson &&
          other.isCorrect == this.isCorrect &&
          other.durationMs == this.durationMs &&
          other.answeredAt == this.answeredAt &&
          other.synced == this.synced);
}

class AttemptsCompanion extends UpdateCompanion<Attempt> {
  final Value<String> id;
  final Value<String> questionId;
  final Value<String> deviceId;
  final Value<String> answerJson;
  final Value<bool> isCorrect;
  final Value<int?> durationMs;
  final Value<int> answeredAt;
  final Value<bool> synced;
  final Value<int> rowid;
  const AttemptsCompanion({
    this.id = const Value.absent(),
    this.questionId = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.answerJson = const Value.absent(),
    this.isCorrect = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.answeredAt = const Value.absent(),
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AttemptsCompanion.insert({
    required String id,
    required String questionId,
    required String deviceId,
    required String answerJson,
    required bool isCorrect,
    this.durationMs = const Value.absent(),
    required int answeredAt,
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       questionId = Value(questionId),
       deviceId = Value(deviceId),
       answerJson = Value(answerJson),
       isCorrect = Value(isCorrect),
       answeredAt = Value(answeredAt);
  static Insertable<Attempt> custom({
    Expression<String>? id,
    Expression<String>? questionId,
    Expression<String>? deviceId,
    Expression<String>? answerJson,
    Expression<bool>? isCorrect,
    Expression<int>? durationMs,
    Expression<int>? answeredAt,
    Expression<bool>? synced,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (questionId != null) 'question_id': questionId,
      if (deviceId != null) 'device_id': deviceId,
      if (answerJson != null) 'answer_json': answerJson,
      if (isCorrect != null) 'is_correct': isCorrect,
      if (durationMs != null) 'duration_ms': durationMs,
      if (answeredAt != null) 'answered_at': answeredAt,
      if (synced != null) 'synced': synced,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AttemptsCompanion copyWith({
    Value<String>? id,
    Value<String>? questionId,
    Value<String>? deviceId,
    Value<String>? answerJson,
    Value<bool>? isCorrect,
    Value<int?>? durationMs,
    Value<int>? answeredAt,
    Value<bool>? synced,
    Value<int>? rowid,
  }) {
    return AttemptsCompanion(
      id: id ?? this.id,
      questionId: questionId ?? this.questionId,
      deviceId: deviceId ?? this.deviceId,
      answerJson: answerJson ?? this.answerJson,
      isCorrect: isCorrect ?? this.isCorrect,
      durationMs: durationMs ?? this.durationMs,
      answeredAt: answeredAt ?? this.answeredAt,
      synced: synced ?? this.synced,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (answerJson.present) {
      map['answer_json'] = Variable<String>(answerJson.value);
    }
    if (isCorrect.present) {
      map['is_correct'] = Variable<bool>(isCorrect.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (answeredAt.present) {
      map['answered_at'] = Variable<int>(answeredAt.value);
    }
    if (synced.present) {
      map['synced'] = Variable<bool>(synced.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AttemptsCompanion(')
          ..write('id: $id, ')
          ..write('questionId: $questionId, ')
          ..write('deviceId: $deviceId, ')
          ..write('answerJson: $answerJson, ')
          ..write('isCorrect: $isCorrect, ')
          ..write('durationMs: $durationMs, ')
          ..write('answeredAt: $answeredAt, ')
          ..write('synced: $synced, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $QuestionStatesTable extends QuestionStates
    with TableInfo<$QuestionStatesTable, QuestionState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QuestionStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fsrsJsonMeta = const VerificationMeta(
    'fsrsJson',
  );
  @override
  late final GeneratedColumn<String> fsrsJson = GeneratedColumn<String>(
    'fsrs_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _dueAtMeta = const VerificationMeta('dueAt');
  @override
  late final GeneratedColumn<int> dueAt = GeneratedColumn<int>(
    'due_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _favoriteMeta = const VerificationMeta(
    'favorite',
  );
  @override
  late final GeneratedColumn<bool> favorite = GeneratedColumn<bool>(
    'favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("favorite" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _wrongCountMeta = const VerificationMeta(
    'wrongCount',
  );
  @override
  late final GeneratedColumn<int> wrongCount = GeneratedColumn<int>(
    'wrong_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dirtyMeta = const VerificationMeta('dirty');
  @override
  late final GeneratedColumn<bool> dirty = GeneratedColumn<bool>(
    'dirty',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("dirty" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    questionId,
    fsrsJson,
    dueAt,
    favorite,
    wrongCount,
    updatedAt,
    dirty,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'question_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<QuestionState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_questionIdMeta);
    }
    if (data.containsKey('fsrs_json')) {
      context.handle(
        _fsrsJsonMeta,
        fsrsJson.isAcceptableOrUnknown(data['fsrs_json']!, _fsrsJsonMeta),
      );
    }
    if (data.containsKey('due_at')) {
      context.handle(
        _dueAtMeta,
        dueAt.isAcceptableOrUnknown(data['due_at']!, _dueAtMeta),
      );
    }
    if (data.containsKey('favorite')) {
      context.handle(
        _favoriteMeta,
        favorite.isAcceptableOrUnknown(data['favorite']!, _favoriteMeta),
      );
    }
    if (data.containsKey('wrong_count')) {
      context.handle(
        _wrongCountMeta,
        wrongCount.isAcceptableOrUnknown(data['wrong_count']!, _wrongCountMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('dirty')) {
      context.handle(
        _dirtyMeta,
        dirty.isAcceptableOrUnknown(data['dirty']!, _dirtyMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {questionId};
  @override
  QuestionState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return QuestionState(
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      )!,
      fsrsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fsrs_json'],
      ),
      dueAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}due_at'],
      ),
      favorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}favorite'],
      )!,
      wrongCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}wrong_count'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      dirty: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}dirty'],
      )!,
    );
  }

  @override
  $QuestionStatesTable createAlias(String alias) {
    return $QuestionStatesTable(attachedDatabase, alias);
  }
}

class QuestionState extends DataClass implements Insertable<QuestionState> {
  final String questionId;
  final String? fsrsJson;
  final int? dueAt;
  final bool favorite;
  final int wrongCount;
  final int updatedAt;
  final bool dirty;
  const QuestionState({
    required this.questionId,
    this.fsrsJson,
    this.dueAt,
    required this.favorite,
    required this.wrongCount,
    required this.updatedAt,
    required this.dirty,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['question_id'] = Variable<String>(questionId);
    if (!nullToAbsent || fsrsJson != null) {
      map['fsrs_json'] = Variable<String>(fsrsJson);
    }
    if (!nullToAbsent || dueAt != null) {
      map['due_at'] = Variable<int>(dueAt);
    }
    map['favorite'] = Variable<bool>(favorite);
    map['wrong_count'] = Variable<int>(wrongCount);
    map['updated_at'] = Variable<int>(updatedAt);
    map['dirty'] = Variable<bool>(dirty);
    return map;
  }

  QuestionStatesCompanion toCompanion(bool nullToAbsent) {
    return QuestionStatesCompanion(
      questionId: Value(questionId),
      fsrsJson: fsrsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(fsrsJson),
      dueAt: dueAt == null && nullToAbsent
          ? const Value.absent()
          : Value(dueAt),
      favorite: Value(favorite),
      wrongCount: Value(wrongCount),
      updatedAt: Value(updatedAt),
      dirty: Value(dirty),
    );
  }

  factory QuestionState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return QuestionState(
      questionId: serializer.fromJson<String>(json['questionId']),
      fsrsJson: serializer.fromJson<String?>(json['fsrsJson']),
      dueAt: serializer.fromJson<int?>(json['dueAt']),
      favorite: serializer.fromJson<bool>(json['favorite']),
      wrongCount: serializer.fromJson<int>(json['wrongCount']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      dirty: serializer.fromJson<bool>(json['dirty']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'questionId': serializer.toJson<String>(questionId),
      'fsrsJson': serializer.toJson<String?>(fsrsJson),
      'dueAt': serializer.toJson<int?>(dueAt),
      'favorite': serializer.toJson<bool>(favorite),
      'wrongCount': serializer.toJson<int>(wrongCount),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'dirty': serializer.toJson<bool>(dirty),
    };
  }

  QuestionState copyWith({
    String? questionId,
    Value<String?> fsrsJson = const Value.absent(),
    Value<int?> dueAt = const Value.absent(),
    bool? favorite,
    int? wrongCount,
    int? updatedAt,
    bool? dirty,
  }) => QuestionState(
    questionId: questionId ?? this.questionId,
    fsrsJson: fsrsJson.present ? fsrsJson.value : this.fsrsJson,
    dueAt: dueAt.present ? dueAt.value : this.dueAt,
    favorite: favorite ?? this.favorite,
    wrongCount: wrongCount ?? this.wrongCount,
    updatedAt: updatedAt ?? this.updatedAt,
    dirty: dirty ?? this.dirty,
  );
  QuestionState copyWithCompanion(QuestionStatesCompanion data) {
    return QuestionState(
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      fsrsJson: data.fsrsJson.present ? data.fsrsJson.value : this.fsrsJson,
      dueAt: data.dueAt.present ? data.dueAt.value : this.dueAt,
      favorite: data.favorite.present ? data.favorite.value : this.favorite,
      wrongCount: data.wrongCount.present
          ? data.wrongCount.value
          : this.wrongCount,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      dirty: data.dirty.present ? data.dirty.value : this.dirty,
    );
  }

  @override
  String toString() {
    return (StringBuffer('QuestionState(')
          ..write('questionId: $questionId, ')
          ..write('fsrsJson: $fsrsJson, ')
          ..write('dueAt: $dueAt, ')
          ..write('favorite: $favorite, ')
          ..write('wrongCount: $wrongCount, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('dirty: $dirty')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    questionId,
    fsrsJson,
    dueAt,
    favorite,
    wrongCount,
    updatedAt,
    dirty,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QuestionState &&
          other.questionId == this.questionId &&
          other.fsrsJson == this.fsrsJson &&
          other.dueAt == this.dueAt &&
          other.favorite == this.favorite &&
          other.wrongCount == this.wrongCount &&
          other.updatedAt == this.updatedAt &&
          other.dirty == this.dirty);
}

class QuestionStatesCompanion extends UpdateCompanion<QuestionState> {
  final Value<String> questionId;
  final Value<String?> fsrsJson;
  final Value<int?> dueAt;
  final Value<bool> favorite;
  final Value<int> wrongCount;
  final Value<int> updatedAt;
  final Value<bool> dirty;
  final Value<int> rowid;
  const QuestionStatesCompanion({
    this.questionId = const Value.absent(),
    this.fsrsJson = const Value.absent(),
    this.dueAt = const Value.absent(),
    this.favorite = const Value.absent(),
    this.wrongCount = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  QuestionStatesCompanion.insert({
    required String questionId,
    this.fsrsJson = const Value.absent(),
    this.dueAt = const Value.absent(),
    this.favorite = const Value.absent(),
    this.wrongCount = const Value.absent(),
    required int updatedAt,
    this.dirty = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : questionId = Value(questionId),
       updatedAt = Value(updatedAt);
  static Insertable<QuestionState> custom({
    Expression<String>? questionId,
    Expression<String>? fsrsJson,
    Expression<int>? dueAt,
    Expression<bool>? favorite,
    Expression<int>? wrongCount,
    Expression<int>? updatedAt,
    Expression<bool>? dirty,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (questionId != null) 'question_id': questionId,
      if (fsrsJson != null) 'fsrs_json': fsrsJson,
      if (dueAt != null) 'due_at': dueAt,
      if (favorite != null) 'favorite': favorite,
      if (wrongCount != null) 'wrong_count': wrongCount,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (dirty != null) 'dirty': dirty,
      if (rowid != null) 'rowid': rowid,
    });
  }

  QuestionStatesCompanion copyWith({
    Value<String>? questionId,
    Value<String?>? fsrsJson,
    Value<int?>? dueAt,
    Value<bool>? favorite,
    Value<int>? wrongCount,
    Value<int>? updatedAt,
    Value<bool>? dirty,
    Value<int>? rowid,
  }) {
    return QuestionStatesCompanion(
      questionId: questionId ?? this.questionId,
      fsrsJson: fsrsJson ?? this.fsrsJson,
      dueAt: dueAt ?? this.dueAt,
      favorite: favorite ?? this.favorite,
      wrongCount: wrongCount ?? this.wrongCount,
      updatedAt: updatedAt ?? this.updatedAt,
      dirty: dirty ?? this.dirty,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (fsrsJson.present) {
      map['fsrs_json'] = Variable<String>(fsrsJson.value);
    }
    if (dueAt.present) {
      map['due_at'] = Variable<int>(dueAt.value);
    }
    if (favorite.present) {
      map['favorite'] = Variable<bool>(favorite.value);
    }
    if (wrongCount.present) {
      map['wrong_count'] = Variable<int>(wrongCount.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (dirty.present) {
      map['dirty'] = Variable<bool>(dirty.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QuestionStatesCompanion(')
          ..write('questionId: $questionId, ')
          ..write('fsrsJson: $fsrsJson, ')
          ..write('dueAt: $dueAt, ')
          ..write('favorite: $favorite, ')
          ..write('wrongCount: $wrongCount, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('dirty: $dirty, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingFlagsTable extends PendingFlags
    with TableInfo<$PendingFlagsTable, PendingFlag> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingFlagsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _questionIdMeta = const VerificationMeta(
    'questionId',
  );
  @override
  late final GeneratedColumn<String> questionId = GeneratedColumn<String>(
    'question_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [questionId, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_flags';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingFlag> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('question_id')) {
      context.handle(
        _questionIdMeta,
        questionId.isAcceptableOrUnknown(data['question_id']!, _questionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_questionIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {questionId};
  @override
  PendingFlag map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingFlag(
      questionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}question_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $PendingFlagsTable createAlias(String alias) {
    return $PendingFlagsTable(attachedDatabase, alias);
  }
}

class PendingFlag extends DataClass implements Insertable<PendingFlag> {
  final String questionId;
  final int createdAt;
  const PendingFlag({required this.questionId, required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['question_id'] = Variable<String>(questionId);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  PendingFlagsCompanion toCompanion(bool nullToAbsent) {
    return PendingFlagsCompanion(
      questionId: Value(questionId),
      createdAt: Value(createdAt),
    );
  }

  factory PendingFlag.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingFlag(
      questionId: serializer.fromJson<String>(json['questionId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'questionId': serializer.toJson<String>(questionId),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  PendingFlag copyWith({String? questionId, int? createdAt}) => PendingFlag(
    questionId: questionId ?? this.questionId,
    createdAt: createdAt ?? this.createdAt,
  );
  PendingFlag copyWithCompanion(PendingFlagsCompanion data) {
    return PendingFlag(
      questionId: data.questionId.present
          ? data.questionId.value
          : this.questionId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingFlag(')
          ..write('questionId: $questionId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(questionId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingFlag &&
          other.questionId == this.questionId &&
          other.createdAt == this.createdAt);
}

class PendingFlagsCompanion extends UpdateCompanion<PendingFlag> {
  final Value<String> questionId;
  final Value<int> createdAt;
  final Value<int> rowid;
  const PendingFlagsCompanion({
    this.questionId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PendingFlagsCompanion.insert({
    required String questionId,
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : questionId = Value(questionId),
       createdAt = Value(createdAt);
  static Insertable<PendingFlag> custom({
    Expression<String>? questionId,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (questionId != null) 'question_id': questionId,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PendingFlagsCompanion copyWith({
    Value<String>? questionId,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return PendingFlagsCompanion(
      questionId: questionId ?? this.questionId,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (questionId.present) {
      map['question_id'] = Variable<String>(questionId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingFlagsCompanion(')
          ..write('questionId: $questionId, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncMetaTable extends SyncMeta
    with TableInfo<$SyncMetaTable, SyncMetaData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<int> value = GeneratedColumn<int>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncMetaData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SyncMetaData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncMetaData(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SyncMetaTable createAlias(String alias) {
    return $SyncMetaTable(attachedDatabase, alias);
  }
}

class SyncMetaData extends DataClass implements Insertable<SyncMetaData> {
  final String key;
  final int value;
  const SyncMetaData({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<int>(value);
    return map;
  }

  SyncMetaCompanion toCompanion(bool nullToAbsent) {
    return SyncMetaCompanion(key: Value(key), value: Value(value));
  }

  factory SyncMetaData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncMetaData(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<int>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<int>(value),
    };
  }

  SyncMetaData copyWith({String? key, int? value}) =>
      SyncMetaData(key: key ?? this.key, value: value ?? this.value);
  SyncMetaData copyWithCompanion(SyncMetaCompanion data) {
    return SyncMetaData(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaData(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncMetaData &&
          other.key == this.key &&
          other.value == this.value);
}

class SyncMetaCompanion extends UpdateCompanion<SyncMetaData> {
  final Value<String> key;
  final Value<int> value;
  final Value<int> rowid;
  const SyncMetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncMetaCompanion.insert({
    required String key,
    required int value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<SyncMetaData> custom({
    Expression<String>? key,
    Expression<int>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncMetaCompanion copyWith({
    Value<String>? key,
    Value<int>? value,
    Value<int>? rowid,
  }) {
    return SyncMetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<int>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncMetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ExamsTable extends Exams with TableInfo<$ExamsTable, ExamRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExamsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bankIdMeta = const VerificationMeta('bankId');
  @override
  late final GeneratedColumn<String> bankId = GeneratedColumn<String>(
    'bank_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
    'finished_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _totalMeta = const VerificationMeta('total');
  @override
  late final GeneratedColumn<int> total = GeneratedColumn<int>(
    'total',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _correctMeta = const VerificationMeta(
    'correct',
  );
  @override
  late final GeneratedColumn<int> correct = GeneratedColumn<int>(
    'correct',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _answeredMeta = const VerificationMeta(
    'answered',
  );
  @override
  late final GeneratedColumn<int> answered = GeneratedColumn<int>(
    'answered',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _percentMeta = const VerificationMeta(
    'percent',
  );
  @override
  late final GeneratedColumn<int> percent = GeneratedColumn<int>(
    'percent',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _passedMeta = const VerificationMeta('passed');
  @override
  late final GeneratedColumn<bool> passed = GeneratedColumn<bool>(
    'passed',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("passed" IN (0, 1))',
    ),
  );
  static const VerificationMeta _limitSecMeta = const VerificationMeta(
    'limitSec',
  );
  @override
  late final GeneratedColumn<int> limitSec = GeneratedColumn<int>(
    'limit_sec',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _usedMsMeta = const VerificationMeta('usedMs');
  @override
  late final GeneratedColumn<int> usedMs = GeneratedColumn<int>(
    'used_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deviceIdMeta = const VerificationMeta(
    'deviceId',
  );
  @override
  late final GeneratedColumn<String> deviceId = GeneratedColumn<String>(
    'device_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _itemsJsonMeta = const VerificationMeta(
    'itemsJson',
  );
  @override
  late final GeneratedColumn<String> itemsJson = GeneratedColumn<String>(
    'items_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('[]'),
  );
  static const VerificationMeta _syncedMeta = const VerificationMeta('synced');
  @override
  late final GeneratedColumn<bool> synced = GeneratedColumn<bool>(
    'synced',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("synced" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    bankId,
    title,
    finishedAt,
    total,
    correct,
    answered,
    percent,
    passed,
    limitSec,
    usedMs,
    deviceId,
    itemsJson,
    synced,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'exams';
  @override
  VerificationContext validateIntegrity(
    Insertable<ExamRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('bank_id')) {
      context.handle(
        _bankIdMeta,
        bankId.isAcceptableOrUnknown(data['bank_id']!, _bankIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bankIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_finishedAtMeta);
    }
    if (data.containsKey('total')) {
      context.handle(
        _totalMeta,
        total.isAcceptableOrUnknown(data['total']!, _totalMeta),
      );
    } else if (isInserting) {
      context.missing(_totalMeta);
    }
    if (data.containsKey('correct')) {
      context.handle(
        _correctMeta,
        correct.isAcceptableOrUnknown(data['correct']!, _correctMeta),
      );
    } else if (isInserting) {
      context.missing(_correctMeta);
    }
    if (data.containsKey('answered')) {
      context.handle(
        _answeredMeta,
        answered.isAcceptableOrUnknown(data['answered']!, _answeredMeta),
      );
    } else if (isInserting) {
      context.missing(_answeredMeta);
    }
    if (data.containsKey('percent')) {
      context.handle(
        _percentMeta,
        percent.isAcceptableOrUnknown(data['percent']!, _percentMeta),
      );
    } else if (isInserting) {
      context.missing(_percentMeta);
    }
    if (data.containsKey('passed')) {
      context.handle(
        _passedMeta,
        passed.isAcceptableOrUnknown(data['passed']!, _passedMeta),
      );
    } else if (isInserting) {
      context.missing(_passedMeta);
    }
    if (data.containsKey('limit_sec')) {
      context.handle(
        _limitSecMeta,
        limitSec.isAcceptableOrUnknown(data['limit_sec']!, _limitSecMeta),
      );
    }
    if (data.containsKey('used_ms')) {
      context.handle(
        _usedMsMeta,
        usedMs.isAcceptableOrUnknown(data['used_ms']!, _usedMsMeta),
      );
    } else if (isInserting) {
      context.missing(_usedMsMeta);
    }
    if (data.containsKey('device_id')) {
      context.handle(
        _deviceIdMeta,
        deviceId.isAcceptableOrUnknown(data['device_id']!, _deviceIdMeta),
      );
    }
    if (data.containsKey('items_json')) {
      context.handle(
        _itemsJsonMeta,
        itemsJson.isAcceptableOrUnknown(data['items_json']!, _itemsJsonMeta),
      );
    }
    if (data.containsKey('synced')) {
      context.handle(
        _syncedMeta,
        synced.isAcceptableOrUnknown(data['synced']!, _syncedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ExamRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ExamRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      bankId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bank_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}finished_at'],
      )!,
      total: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total'],
      )!,
      correct: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}correct'],
      )!,
      answered: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}answered'],
      )!,
      percent: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}percent'],
      )!,
      passed: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}passed'],
      )!,
      limitSec: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}limit_sec'],
      ),
      usedMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}used_ms'],
      )!,
      deviceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}device_id'],
      )!,
      itemsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}items_json'],
      )!,
      synced: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}synced'],
      )!,
    );
  }

  @override
  $ExamsTable createAlias(String alias) {
    return $ExamsTable(attachedDatabase, alias);
  }
}

class ExamRow extends DataClass implements Insertable<ExamRow> {
  final String id;
  final String bankId;
  final String title;
  final int finishedAt;
  final int total;
  final int correct;
  final int answered;
  final int percent;
  final bool passed;
  final int? limitSec;
  final int usedMs;
  final String deviceId;
  final String itemsJson;
  final bool synced;
  const ExamRow({
    required this.id,
    required this.bankId,
    required this.title,
    required this.finishedAt,
    required this.total,
    required this.correct,
    required this.answered,
    required this.percent,
    required this.passed,
    this.limitSec,
    required this.usedMs,
    required this.deviceId,
    required this.itemsJson,
    required this.synced,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['bank_id'] = Variable<String>(bankId);
    map['title'] = Variable<String>(title);
    map['finished_at'] = Variable<int>(finishedAt);
    map['total'] = Variable<int>(total);
    map['correct'] = Variable<int>(correct);
    map['answered'] = Variable<int>(answered);
    map['percent'] = Variable<int>(percent);
    map['passed'] = Variable<bool>(passed);
    if (!nullToAbsent || limitSec != null) {
      map['limit_sec'] = Variable<int>(limitSec);
    }
    map['used_ms'] = Variable<int>(usedMs);
    map['device_id'] = Variable<String>(deviceId);
    map['items_json'] = Variable<String>(itemsJson);
    map['synced'] = Variable<bool>(synced);
    return map;
  }

  ExamsCompanion toCompanion(bool nullToAbsent) {
    return ExamsCompanion(
      id: Value(id),
      bankId: Value(bankId),
      title: Value(title),
      finishedAt: Value(finishedAt),
      total: Value(total),
      correct: Value(correct),
      answered: Value(answered),
      percent: Value(percent),
      passed: Value(passed),
      limitSec: limitSec == null && nullToAbsent
          ? const Value.absent()
          : Value(limitSec),
      usedMs: Value(usedMs),
      deviceId: Value(deviceId),
      itemsJson: Value(itemsJson),
      synced: Value(synced),
    );
  }

  factory ExamRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ExamRow(
      id: serializer.fromJson<String>(json['id']),
      bankId: serializer.fromJson<String>(json['bankId']),
      title: serializer.fromJson<String>(json['title']),
      finishedAt: serializer.fromJson<int>(json['finishedAt']),
      total: serializer.fromJson<int>(json['total']),
      correct: serializer.fromJson<int>(json['correct']),
      answered: serializer.fromJson<int>(json['answered']),
      percent: serializer.fromJson<int>(json['percent']),
      passed: serializer.fromJson<bool>(json['passed']),
      limitSec: serializer.fromJson<int?>(json['limitSec']),
      usedMs: serializer.fromJson<int>(json['usedMs']),
      deviceId: serializer.fromJson<String>(json['deviceId']),
      itemsJson: serializer.fromJson<String>(json['itemsJson']),
      synced: serializer.fromJson<bool>(json['synced']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'bankId': serializer.toJson<String>(bankId),
      'title': serializer.toJson<String>(title),
      'finishedAt': serializer.toJson<int>(finishedAt),
      'total': serializer.toJson<int>(total),
      'correct': serializer.toJson<int>(correct),
      'answered': serializer.toJson<int>(answered),
      'percent': serializer.toJson<int>(percent),
      'passed': serializer.toJson<bool>(passed),
      'limitSec': serializer.toJson<int?>(limitSec),
      'usedMs': serializer.toJson<int>(usedMs),
      'deviceId': serializer.toJson<String>(deviceId),
      'itemsJson': serializer.toJson<String>(itemsJson),
      'synced': serializer.toJson<bool>(synced),
    };
  }

  ExamRow copyWith({
    String? id,
    String? bankId,
    String? title,
    int? finishedAt,
    int? total,
    int? correct,
    int? answered,
    int? percent,
    bool? passed,
    Value<int?> limitSec = const Value.absent(),
    int? usedMs,
    String? deviceId,
    String? itemsJson,
    bool? synced,
  }) => ExamRow(
    id: id ?? this.id,
    bankId: bankId ?? this.bankId,
    title: title ?? this.title,
    finishedAt: finishedAt ?? this.finishedAt,
    total: total ?? this.total,
    correct: correct ?? this.correct,
    answered: answered ?? this.answered,
    percent: percent ?? this.percent,
    passed: passed ?? this.passed,
    limitSec: limitSec.present ? limitSec.value : this.limitSec,
    usedMs: usedMs ?? this.usedMs,
    deviceId: deviceId ?? this.deviceId,
    itemsJson: itemsJson ?? this.itemsJson,
    synced: synced ?? this.synced,
  );
  ExamRow copyWithCompanion(ExamsCompanion data) {
    return ExamRow(
      id: data.id.present ? data.id.value : this.id,
      bankId: data.bankId.present ? data.bankId.value : this.bankId,
      title: data.title.present ? data.title.value : this.title,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      total: data.total.present ? data.total.value : this.total,
      correct: data.correct.present ? data.correct.value : this.correct,
      answered: data.answered.present ? data.answered.value : this.answered,
      percent: data.percent.present ? data.percent.value : this.percent,
      passed: data.passed.present ? data.passed.value : this.passed,
      limitSec: data.limitSec.present ? data.limitSec.value : this.limitSec,
      usedMs: data.usedMs.present ? data.usedMs.value : this.usedMs,
      deviceId: data.deviceId.present ? data.deviceId.value : this.deviceId,
      itemsJson: data.itemsJson.present ? data.itemsJson.value : this.itemsJson,
      synced: data.synced.present ? data.synced.value : this.synced,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ExamRow(')
          ..write('id: $id, ')
          ..write('bankId: $bankId, ')
          ..write('title: $title, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('total: $total, ')
          ..write('correct: $correct, ')
          ..write('answered: $answered, ')
          ..write('percent: $percent, ')
          ..write('passed: $passed, ')
          ..write('limitSec: $limitSec, ')
          ..write('usedMs: $usedMs, ')
          ..write('deviceId: $deviceId, ')
          ..write('itemsJson: $itemsJson, ')
          ..write('synced: $synced')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    bankId,
    title,
    finishedAt,
    total,
    correct,
    answered,
    percent,
    passed,
    limitSec,
    usedMs,
    deviceId,
    itemsJson,
    synced,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ExamRow &&
          other.id == this.id &&
          other.bankId == this.bankId &&
          other.title == this.title &&
          other.finishedAt == this.finishedAt &&
          other.total == this.total &&
          other.correct == this.correct &&
          other.answered == this.answered &&
          other.percent == this.percent &&
          other.passed == this.passed &&
          other.limitSec == this.limitSec &&
          other.usedMs == this.usedMs &&
          other.deviceId == this.deviceId &&
          other.itemsJson == this.itemsJson &&
          other.synced == this.synced);
}

class ExamsCompanion extends UpdateCompanion<ExamRow> {
  final Value<String> id;
  final Value<String> bankId;
  final Value<String> title;
  final Value<int> finishedAt;
  final Value<int> total;
  final Value<int> correct;
  final Value<int> answered;
  final Value<int> percent;
  final Value<bool> passed;
  final Value<int?> limitSec;
  final Value<int> usedMs;
  final Value<String> deviceId;
  final Value<String> itemsJson;
  final Value<bool> synced;
  final Value<int> rowid;
  const ExamsCompanion({
    this.id = const Value.absent(),
    this.bankId = const Value.absent(),
    this.title = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.total = const Value.absent(),
    this.correct = const Value.absent(),
    this.answered = const Value.absent(),
    this.percent = const Value.absent(),
    this.passed = const Value.absent(),
    this.limitSec = const Value.absent(),
    this.usedMs = const Value.absent(),
    this.deviceId = const Value.absent(),
    this.itemsJson = const Value.absent(),
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ExamsCompanion.insert({
    required String id,
    required String bankId,
    required String title,
    required int finishedAt,
    required int total,
    required int correct,
    required int answered,
    required int percent,
    required bool passed,
    this.limitSec = const Value.absent(),
    required int usedMs,
    this.deviceId = const Value.absent(),
    this.itemsJson = const Value.absent(),
    this.synced = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       bankId = Value(bankId),
       title = Value(title),
       finishedAt = Value(finishedAt),
       total = Value(total),
       correct = Value(correct),
       answered = Value(answered),
       percent = Value(percent),
       passed = Value(passed),
       usedMs = Value(usedMs);
  static Insertable<ExamRow> custom({
    Expression<String>? id,
    Expression<String>? bankId,
    Expression<String>? title,
    Expression<int>? finishedAt,
    Expression<int>? total,
    Expression<int>? correct,
    Expression<int>? answered,
    Expression<int>? percent,
    Expression<bool>? passed,
    Expression<int>? limitSec,
    Expression<int>? usedMs,
    Expression<String>? deviceId,
    Expression<String>? itemsJson,
    Expression<bool>? synced,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bankId != null) 'bank_id': bankId,
      if (title != null) 'title': title,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (total != null) 'total': total,
      if (correct != null) 'correct': correct,
      if (answered != null) 'answered': answered,
      if (percent != null) 'percent': percent,
      if (passed != null) 'passed': passed,
      if (limitSec != null) 'limit_sec': limitSec,
      if (usedMs != null) 'used_ms': usedMs,
      if (deviceId != null) 'device_id': deviceId,
      if (itemsJson != null) 'items_json': itemsJson,
      if (synced != null) 'synced': synced,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ExamsCompanion copyWith({
    Value<String>? id,
    Value<String>? bankId,
    Value<String>? title,
    Value<int>? finishedAt,
    Value<int>? total,
    Value<int>? correct,
    Value<int>? answered,
    Value<int>? percent,
    Value<bool>? passed,
    Value<int?>? limitSec,
    Value<int>? usedMs,
    Value<String>? deviceId,
    Value<String>? itemsJson,
    Value<bool>? synced,
    Value<int>? rowid,
  }) {
    return ExamsCompanion(
      id: id ?? this.id,
      bankId: bankId ?? this.bankId,
      title: title ?? this.title,
      finishedAt: finishedAt ?? this.finishedAt,
      total: total ?? this.total,
      correct: correct ?? this.correct,
      answered: answered ?? this.answered,
      percent: percent ?? this.percent,
      passed: passed ?? this.passed,
      limitSec: limitSec ?? this.limitSec,
      usedMs: usedMs ?? this.usedMs,
      deviceId: deviceId ?? this.deviceId,
      itemsJson: itemsJson ?? this.itemsJson,
      synced: synced ?? this.synced,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (bankId.present) {
      map['bank_id'] = Variable<String>(bankId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(finishedAt.value);
    }
    if (total.present) {
      map['total'] = Variable<int>(total.value);
    }
    if (correct.present) {
      map['correct'] = Variable<int>(correct.value);
    }
    if (answered.present) {
      map['answered'] = Variable<int>(answered.value);
    }
    if (percent.present) {
      map['percent'] = Variable<int>(percent.value);
    }
    if (passed.present) {
      map['passed'] = Variable<bool>(passed.value);
    }
    if (limitSec.present) {
      map['limit_sec'] = Variable<int>(limitSec.value);
    }
    if (usedMs.present) {
      map['used_ms'] = Variable<int>(usedMs.value);
    }
    if (deviceId.present) {
      map['device_id'] = Variable<String>(deviceId.value);
    }
    if (itemsJson.present) {
      map['items_json'] = Variable<String>(itemsJson.value);
    }
    if (synced.present) {
      map['synced'] = Variable<bool>(synced.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExamsCompanion(')
          ..write('id: $id, ')
          ..write('bankId: $bankId, ')
          ..write('title: $title, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('total: $total, ')
          ..write('correct: $correct, ')
          ..write('answered: $answered, ')
          ..write('percent: $percent, ')
          ..write('passed: $passed, ')
          ..write('limitSec: $limitSec, ')
          ..write('usedMs: $usedMs, ')
          ..write('deviceId: $deviceId, ')
          ..write('itemsJson: $itemsJson, ')
          ..write('synced: $synced, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ExamDraftsTable extends ExamDrafts
    with TableInfo<$ExamDraftsTable, ExamDraftRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ExamDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _bankIdMeta = const VerificationMeta('bankId');
  @override
  late final GeneratedColumn<String> bankId = GeneratedColumn<String>(
    'bank_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataJsonMeta = const VerificationMeta(
    'dataJson',
  );
  @override
  late final GeneratedColumn<String> dataJson = GeneratedColumn<String>(
    'data_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savedAtMeta = const VerificationMeta(
    'savedAt',
  );
  @override
  late final GeneratedColumn<int> savedAt = GeneratedColumn<int>(
    'saved_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [bankId, dataJson, savedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'exam_drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<ExamDraftRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('bank_id')) {
      context.handle(
        _bankIdMeta,
        bankId.isAcceptableOrUnknown(data['bank_id']!, _bankIdMeta),
      );
    } else if (isInserting) {
      context.missing(_bankIdMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_dataJsonMeta);
    }
    if (data.containsKey('saved_at')) {
      context.handle(
        _savedAtMeta,
        savedAt.isAcceptableOrUnknown(data['saved_at']!, _savedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_savedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {bankId};
  @override
  ExamDraftRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ExamDraftRow(
      bankId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bank_id'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      savedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}saved_at'],
      )!,
    );
  }

  @override
  $ExamDraftsTable createAlias(String alias) {
    return $ExamDraftsTable(attachedDatabase, alias);
  }
}

class ExamDraftRow extends DataClass implements Insertable<ExamDraftRow> {
  final String bankId;
  final String dataJson;
  final int savedAt;
  const ExamDraftRow({
    required this.bankId,
    required this.dataJson,
    required this.savedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['bank_id'] = Variable<String>(bankId);
    map['data_json'] = Variable<String>(dataJson);
    map['saved_at'] = Variable<int>(savedAt);
    return map;
  }

  ExamDraftsCompanion toCompanion(bool nullToAbsent) {
    return ExamDraftsCompanion(
      bankId: Value(bankId),
      dataJson: Value(dataJson),
      savedAt: Value(savedAt),
    );
  }

  factory ExamDraftRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ExamDraftRow(
      bankId: serializer.fromJson<String>(json['bankId']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      savedAt: serializer.fromJson<int>(json['savedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'bankId': serializer.toJson<String>(bankId),
      'dataJson': serializer.toJson<String>(dataJson),
      'savedAt': serializer.toJson<int>(savedAt),
    };
  }

  ExamDraftRow copyWith({String? bankId, String? dataJson, int? savedAt}) =>
      ExamDraftRow(
        bankId: bankId ?? this.bankId,
        dataJson: dataJson ?? this.dataJson,
        savedAt: savedAt ?? this.savedAt,
      );
  ExamDraftRow copyWithCompanion(ExamDraftsCompanion data) {
    return ExamDraftRow(
      bankId: data.bankId.present ? data.bankId.value : this.bankId,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      savedAt: data.savedAt.present ? data.savedAt.value : this.savedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ExamDraftRow(')
          ..write('bankId: $bankId, ')
          ..write('dataJson: $dataJson, ')
          ..write('savedAt: $savedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(bankId, dataJson, savedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ExamDraftRow &&
          other.bankId == this.bankId &&
          other.dataJson == this.dataJson &&
          other.savedAt == this.savedAt);
}

class ExamDraftsCompanion extends UpdateCompanion<ExamDraftRow> {
  final Value<String> bankId;
  final Value<String> dataJson;
  final Value<int> savedAt;
  final Value<int> rowid;
  const ExamDraftsCompanion({
    this.bankId = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.savedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ExamDraftsCompanion.insert({
    required String bankId,
    required String dataJson,
    required int savedAt,
    this.rowid = const Value.absent(),
  }) : bankId = Value(bankId),
       dataJson = Value(dataJson),
       savedAt = Value(savedAt);
  static Insertable<ExamDraftRow> custom({
    Expression<String>? bankId,
    Expression<String>? dataJson,
    Expression<int>? savedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (bankId != null) 'bank_id': bankId,
      if (dataJson != null) 'data_json': dataJson,
      if (savedAt != null) 'saved_at': savedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ExamDraftsCompanion copyWith({
    Value<String>? bankId,
    Value<String>? dataJson,
    Value<int>? savedAt,
    Value<int>? rowid,
  }) {
    return ExamDraftsCompanion(
      bankId: bankId ?? this.bankId,
      dataJson: dataJson ?? this.dataJson,
      savedAt: savedAt ?? this.savedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (bankId.present) {
      map['bank_id'] = Variable<String>(bankId.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (savedAt.present) {
      map['saved_at'] = Variable<int>(savedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ExamDraftsCompanion(')
          ..write('bankId: $bankId, ')
          ..write('dataJson: $dataJson, ')
          ..write('savedAt: $savedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $BanksTable banks = $BanksTable(this);
  late final $QuestionsTable questions = $QuestionsTable(this);
  late final $AttemptsTable attempts = $AttemptsTable(this);
  late final $QuestionStatesTable questionStates = $QuestionStatesTable(this);
  late final $PendingFlagsTable pendingFlags = $PendingFlagsTable(this);
  late final $SyncMetaTable syncMeta = $SyncMetaTable(this);
  late final $ExamsTable exams = $ExamsTable(this);
  late final $ExamDraftsTable examDrafts = $ExamDraftsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    banks,
    questions,
    attempts,
    questionStates,
    pendingFlags,
    syncMeta,
    exams,
    examDrafts,
  ];
}

typedef $$BanksTableCreateCompanionBuilder = BanksCompanion Function({
  required String id,
  required String title,
  Value<String> description,
  Value<int> questionCount,
  Value<int> rowid,
});
typedef $$BanksTableUpdateCompanionBuilder = BanksCompanion Function({
  Value<String> id,
  Value<String> title,
  Value<String> description,
  Value<int> questionCount,
  Value<int> rowid,
});

class $$BanksTableFilterComposer extends Composer<_$AppDatabase, $BanksTable> {
  $$BanksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get questionCount => $composableBuilder(
    column: $table.questionCount,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BanksTableOrderingComposer
    extends Composer<_$AppDatabase, $BanksTable> {
  $$BanksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get questionCount => $composableBuilder(
    column: $table.questionCount,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BanksTableAnnotationComposer
    extends Composer<_$AppDatabase, $BanksTable> {
  $$BanksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get description => $composableBuilder(
    column: $table.description,
    builder: (column) => column,
  );

  GeneratedColumn<int> get questionCount => $composableBuilder(
    column: $table.questionCount,
    builder: (column) => column,
  );
}

class $$BanksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BanksTable,
          Bank,
          $$BanksTableFilterComposer,
          $$BanksTableOrderingComposer,
          $$BanksTableAnnotationComposer,
          $$BanksTableCreateCompanionBuilder,
          $$BanksTableUpdateCompanionBuilder,
          (Bank, BaseReferences<_$AppDatabase, $BanksTable, Bank>),
          Bank,
          PrefetchHooks Function()
        > {
  $$BanksTableTableManager(_$AppDatabase db, $BanksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BanksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BanksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BanksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> description = const Value.absent(),
                Value<int> questionCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BanksCompanion(
                id: id,
                title: title,
                description: description,
                questionCount: questionCount,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                Value<String> description = const Value.absent(),
                Value<int> questionCount = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BanksCompanion.insert(
                id: id,
                title: title,
                description: description,
                questionCount: questionCount,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BanksTable, Bank>(table),
                  BaseReferences<_$AppDatabase, $BanksTable, Bank>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BanksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BanksTable,
      Bank,
      $$BanksTableFilterComposer,
      $$BanksTableOrderingComposer,
      $$BanksTableAnnotationComposer,
      $$BanksTableCreateCompanionBuilder,
      $$BanksTableUpdateCompanionBuilder,
      (Bank, BaseReferences<_$AppDatabase, $BanksTable, Bank>),
      Bank,
      PrefetchHooks Function()
    >;
typedef $$QuestionsTableCreateCompanionBuilder = QuestionsCompanion Function({
  required String id,
  required String bankId,
  required String type,
  required String stem,
  required String optionsJson,
  required String answerJson,
  Value<String> explanation,
  Value<int> difficulty,
  Value<String> tagsJson,
  Value<String> sourceQuote,
  required int syncSeq,
  Value<bool> hidden,
  Value<int> rowid,
});
typedef $$QuestionsTableUpdateCompanionBuilder = QuestionsCompanion Function({
  Value<String> id,
  Value<String> bankId,
  Value<String> type,
  Value<String> stem,
  Value<String> optionsJson,
  Value<String> answerJson,
  Value<String> explanation,
  Value<int> difficulty,
  Value<String> tagsJson,
  Value<String> sourceQuote,
  Value<int> syncSeq,
  Value<bool> hidden,
  Value<int> rowid,
});

class $$QuestionsTableFilterComposer
    extends Composer<_$AppDatabase, $QuestionsTable> {
  $$QuestionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bankId => $composableBuilder(
    column: $table.bankId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stem => $composableBuilder(
    column: $table.stem,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get optionsJson => $composableBuilder(
    column: $table.optionsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get answerJson => $composableBuilder(
    column: $table.answerJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get explanation => $composableBuilder(
    column: $table.explanation,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceQuote => $composableBuilder(
    column: $table.sourceQuote,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncSeq => $composableBuilder(
    column: $table.syncSeq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QuestionsTableOrderingComposer
    extends Composer<_$AppDatabase, $QuestionsTable> {
  $$QuestionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bankId => $composableBuilder(
    column: $table.bankId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stem => $composableBuilder(
    column: $table.stem,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get optionsJson => $composableBuilder(
    column: $table.optionsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get answerJson => $composableBuilder(
    column: $table.answerJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get explanation => $composableBuilder(
    column: $table.explanation,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagsJson => $composableBuilder(
    column: $table.tagsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceQuote => $composableBuilder(
    column: $table.sourceQuote,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncSeq => $composableBuilder(
    column: $table.syncSeq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hidden => $composableBuilder(
    column: $table.hidden,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QuestionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $QuestionsTable> {
  $$QuestionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bankId =>
      $composableBuilder(column: $table.bankId, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get stem =>
      $composableBuilder(column: $table.stem, builder: (column) => column);

  GeneratedColumn<String> get optionsJson => $composableBuilder(
    column: $table.optionsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get answerJson => $composableBuilder(
    column: $table.answerJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get explanation => $composableBuilder(
    column: $table.explanation,
    builder: (column) => column,
  );

  GeneratedColumn<int> get difficulty => $composableBuilder(
    column: $table.difficulty,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tagsJson =>
      $composableBuilder(column: $table.tagsJson, builder: (column) => column);

  GeneratedColumn<String> get sourceQuote => $composableBuilder(
    column: $table.sourceQuote,
    builder: (column) => column,
  );

  GeneratedColumn<int> get syncSeq =>
      $composableBuilder(column: $table.syncSeq, builder: (column) => column);

  GeneratedColumn<bool> get hidden =>
      $composableBuilder(column: $table.hidden, builder: (column) => column);
}

class $$QuestionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $QuestionsTable,
          Question,
          $$QuestionsTableFilterComposer,
          $$QuestionsTableOrderingComposer,
          $$QuestionsTableAnnotationComposer,
          $$QuestionsTableCreateCompanionBuilder,
          $$QuestionsTableUpdateCompanionBuilder,
          (Question, BaseReferences<_$AppDatabase, $QuestionsTable, Question>),
          Question,
          PrefetchHooks Function()
        > {
  $$QuestionsTableTableManager(_$AppDatabase db, $QuestionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuestionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuestionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuestionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> bankId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> stem = const Value.absent(),
                Value<String> optionsJson = const Value.absent(),
                Value<String> answerJson = const Value.absent(),
                Value<String> explanation = const Value.absent(),
                Value<int> difficulty = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<String> sourceQuote = const Value.absent(),
                Value<int> syncSeq = const Value.absent(),
                Value<bool> hidden = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionsCompanion(
                id: id,
                bankId: bankId,
                type: type,
                stem: stem,
                optionsJson: optionsJson,
                answerJson: answerJson,
                explanation: explanation,
                difficulty: difficulty,
                tagsJson: tagsJson,
                sourceQuote: sourceQuote,
                syncSeq: syncSeq,
                hidden: hidden,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String bankId,
                required String type,
                required String stem,
                required String optionsJson,
                required String answerJson,
                Value<String> explanation = const Value.absent(),
                Value<int> difficulty = const Value.absent(),
                Value<String> tagsJson = const Value.absent(),
                Value<String> sourceQuote = const Value.absent(),
                required int syncSeq,
                Value<bool> hidden = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionsCompanion.insert(
                id: id,
                bankId: bankId,
                type: type,
                stem: stem,
                optionsJson: optionsJson,
                answerJson: answerJson,
                explanation: explanation,
                difficulty: difficulty,
                tagsJson: tagsJson,
                sourceQuote: sourceQuote,
                syncSeq: syncSeq,
                hidden: hidden,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$QuestionsTable, Question>(table),
                  BaseReferences<_$AppDatabase, $QuestionsTable, Question>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QuestionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $QuestionsTable,
      Question,
      $$QuestionsTableFilterComposer,
      $$QuestionsTableOrderingComposer,
      $$QuestionsTableAnnotationComposer,
      $$QuestionsTableCreateCompanionBuilder,
      $$QuestionsTableUpdateCompanionBuilder,
      (Question, BaseReferences<_$AppDatabase, $QuestionsTable, Question>),
      Question,
      PrefetchHooks Function()
    >;
typedef $$AttemptsTableCreateCompanionBuilder = AttemptsCompanion Function({
  required String id,
  required String questionId,
  required String deviceId,
  required String answerJson,
  required bool isCorrect,
  Value<int?> durationMs,
  required int answeredAt,
  Value<bool> synced,
  Value<int> rowid,
});
typedef $$AttemptsTableUpdateCompanionBuilder = AttemptsCompanion Function({
  Value<String> id,
  Value<String> questionId,
  Value<String> deviceId,
  Value<String> answerJson,
  Value<bool> isCorrect,
  Value<int?> durationMs,
  Value<int> answeredAt,
  Value<bool> synced,
  Value<int> rowid,
});

class $$AttemptsTableFilterComposer
    extends Composer<_$AppDatabase, $AttemptsTable> {
  $$AttemptsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get answerJson => $composableBuilder(
    column: $table.answerJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isCorrect => $composableBuilder(
    column: $table.isCorrect,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get answeredAt => $composableBuilder(
    column: $table.answeredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AttemptsTableOrderingComposer
    extends Composer<_$AppDatabase, $AttemptsTable> {
  $$AttemptsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get answerJson => $composableBuilder(
    column: $table.answerJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isCorrect => $composableBuilder(
    column: $table.isCorrect,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get answeredAt => $composableBuilder(
    column: $table.answeredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AttemptsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AttemptsTable> {
  $$AttemptsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get answerJson => $composableBuilder(
    column: $table.answerJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isCorrect =>
      $composableBuilder(column: $table.isCorrect, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get answeredAt => $composableBuilder(
    column: $table.answeredAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get synced =>
      $composableBuilder(column: $table.synced, builder: (column) => column);
}

class $$AttemptsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AttemptsTable,
          Attempt,
          $$AttemptsTableFilterComposer,
          $$AttemptsTableOrderingComposer,
          $$AttemptsTableAnnotationComposer,
          $$AttemptsTableCreateCompanionBuilder,
          $$AttemptsTableUpdateCompanionBuilder,
          (Attempt, BaseReferences<_$AppDatabase, $AttemptsTable, Attempt>),
          Attempt,
          PrefetchHooks Function()
        > {
  $$AttemptsTableTableManager(_$AppDatabase db, $AttemptsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AttemptsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AttemptsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AttemptsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> questionId = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> answerJson = const Value.absent(),
                Value<bool> isCorrect = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<int> answeredAt = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttemptsCompanion(
                id: id,
                questionId: questionId,
                deviceId: deviceId,
                answerJson: answerJson,
                isCorrect: isCorrect,
                durationMs: durationMs,
                answeredAt: answeredAt,
                synced: synced,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String questionId,
                required String deviceId,
                required String answerJson,
                required bool isCorrect,
                Value<int?> durationMs = const Value.absent(),
                required int answeredAt,
                Value<bool> synced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AttemptsCompanion.insert(
                id: id,
                questionId: questionId,
                deviceId: deviceId,
                answerJson: answerJson,
                isCorrect: isCorrect,
                durationMs: durationMs,
                answeredAt: answeredAt,
                synced: synced,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AttemptsTable, Attempt>(table),
                  BaseReferences<_$AppDatabase, $AttemptsTable, Attempt>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AttemptsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AttemptsTable,
      Attempt,
      $$AttemptsTableFilterComposer,
      $$AttemptsTableOrderingComposer,
      $$AttemptsTableAnnotationComposer,
      $$AttemptsTableCreateCompanionBuilder,
      $$AttemptsTableUpdateCompanionBuilder,
      (Attempt, BaseReferences<_$AppDatabase, $AttemptsTable, Attempt>),
      Attempt,
      PrefetchHooks Function()
    >;
typedef $$QuestionStatesTableCreateCompanionBuilder =
    QuestionStatesCompanion Function({
      required String questionId,
      Value<String?> fsrsJson,
      Value<int?> dueAt,
      Value<bool> favorite,
      Value<int> wrongCount,
      required int updatedAt,
      Value<bool> dirty,
      Value<int> rowid,
    });
typedef $$QuestionStatesTableUpdateCompanionBuilder =
    QuestionStatesCompanion Function({
      Value<String> questionId,
      Value<String?> fsrsJson,
      Value<int?> dueAt,
      Value<bool> favorite,
      Value<int> wrongCount,
      Value<int> updatedAt,
      Value<bool> dirty,
      Value<int> rowid,
    });

class $$QuestionStatesTableFilterComposer
    extends Composer<_$AppDatabase, $QuestionStatesTable> {
  $$QuestionStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fsrsJson => $composableBuilder(
    column: $table.fsrsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get dueAt => $composableBuilder(
    column: $table.dueAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get wrongCount => $composableBuilder(
    column: $table.wrongCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QuestionStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $QuestionStatesTable> {
  $$QuestionStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fsrsJson => $composableBuilder(
    column: $table.fsrsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get dueAt => $composableBuilder(
    column: $table.dueAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get wrongCount => $composableBuilder(
    column: $table.wrongCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get dirty => $composableBuilder(
    column: $table.dirty,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QuestionStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $QuestionStatesTable> {
  $$QuestionStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fsrsJson =>
      $composableBuilder(column: $table.fsrsJson, builder: (column) => column);

  GeneratedColumn<int> get dueAt =>
      $composableBuilder(column: $table.dueAt, builder: (column) => column);

  GeneratedColumn<bool> get favorite =>
      $composableBuilder(column: $table.favorite, builder: (column) => column);

  GeneratedColumn<int> get wrongCount => $composableBuilder(
    column: $table.wrongCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get dirty =>
      $composableBuilder(column: $table.dirty, builder: (column) => column);
}

class $$QuestionStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $QuestionStatesTable,
          QuestionState,
          $$QuestionStatesTableFilterComposer,
          $$QuestionStatesTableOrderingComposer,
          $$QuestionStatesTableAnnotationComposer,
          $$QuestionStatesTableCreateCompanionBuilder,
          $$QuestionStatesTableUpdateCompanionBuilder,
          (
            QuestionState,
            BaseReferences<_$AppDatabase, $QuestionStatesTable, QuestionState>,
          ),
          QuestionState,
          PrefetchHooks Function()
        > {
  $$QuestionStatesTableTableManager(
    _$AppDatabase db,
    $QuestionStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QuestionStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QuestionStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QuestionStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> questionId = const Value.absent(),
                Value<String?> fsrsJson = const Value.absent(),
                Value<int?> dueAt = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<int> wrongCount = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<bool> dirty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionStatesCompanion(
                questionId: questionId,
                fsrsJson: fsrsJson,
                dueAt: dueAt,
                favorite: favorite,
                wrongCount: wrongCount,
                updatedAt: updatedAt,
                dirty: dirty,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String questionId,
                Value<String?> fsrsJson = const Value.absent(),
                Value<int?> dueAt = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<int> wrongCount = const Value.absent(),
                required int updatedAt,
                Value<bool> dirty = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QuestionStatesCompanion.insert(
                questionId: questionId,
                fsrsJson: fsrsJson,
                dueAt: dueAt,
                favorite: favorite,
                wrongCount: wrongCount,
                updatedAt: updatedAt,
                dirty: dirty,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$QuestionStatesTable, QuestionState>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $QuestionStatesTable,
                    QuestionState
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QuestionStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $QuestionStatesTable,
      QuestionState,
      $$QuestionStatesTableFilterComposer,
      $$QuestionStatesTableOrderingComposer,
      $$QuestionStatesTableAnnotationComposer,
      $$QuestionStatesTableCreateCompanionBuilder,
      $$QuestionStatesTableUpdateCompanionBuilder,
      (
        QuestionState,
        BaseReferences<_$AppDatabase, $QuestionStatesTable, QuestionState>,
      ),
      QuestionState,
      PrefetchHooks Function()
    >;
typedef $$PendingFlagsTableCreateCompanionBuilder =
    PendingFlagsCompanion Function({
      required String questionId,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$PendingFlagsTableUpdateCompanionBuilder =
    PendingFlagsCompanion Function({
      Value<String> questionId,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$PendingFlagsTableFilterComposer
    extends Composer<_$AppDatabase, $PendingFlagsTable> {
  $$PendingFlagsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PendingFlagsTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingFlagsTable> {
  $$PendingFlagsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PendingFlagsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingFlagsTable> {
  $$PendingFlagsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get questionId => $composableBuilder(
    column: $table.questionId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$PendingFlagsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PendingFlagsTable,
          PendingFlag,
          $$PendingFlagsTableFilterComposer,
          $$PendingFlagsTableOrderingComposer,
          $$PendingFlagsTableAnnotationComposer,
          $$PendingFlagsTableCreateCompanionBuilder,
          $$PendingFlagsTableUpdateCompanionBuilder,
          (
            PendingFlag,
            BaseReferences<_$AppDatabase, $PendingFlagsTable, PendingFlag>,
          ),
          PendingFlag,
          PrefetchHooks Function()
        > {
  $$PendingFlagsTableTableManager(_$AppDatabase db, $PendingFlagsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingFlagsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingFlagsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingFlagsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> questionId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PendingFlagsCompanion(
                questionId: questionId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String questionId,
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => PendingFlagsCompanion.insert(
                questionId: questionId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PendingFlagsTable, PendingFlag>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $PendingFlagsTable,
                    PendingFlag
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PendingFlagsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PendingFlagsTable,
      PendingFlag,
      $$PendingFlagsTableFilterComposer,
      $$PendingFlagsTableOrderingComposer,
      $$PendingFlagsTableAnnotationComposer,
      $$PendingFlagsTableCreateCompanionBuilder,
      $$PendingFlagsTableUpdateCompanionBuilder,
      (
        PendingFlag,
        BaseReferences<_$AppDatabase, $PendingFlagsTable, PendingFlag>,
      ),
      PendingFlag,
      PrefetchHooks Function()
    >;
typedef $$SyncMetaTableCreateCompanionBuilder = SyncMetaCompanion Function({
  required String key,
  required int value,
  Value<int> rowid,
});
typedef $$SyncMetaTableUpdateCompanionBuilder = SyncMetaCompanion Function({
  Value<String> key,
  Value<int> value,
  Value<int> rowid,
});

class $$SyncMetaTableFilterComposer
    extends Composer<_$AppDatabase, $SyncMetaTable> {
  $$SyncMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncMetaTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncMetaTable> {
  $$SyncMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncMetaTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncMetaTable> {
  $$SyncMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<int> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SyncMetaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncMetaTable,
          SyncMetaData,
          $$SyncMetaTableFilterComposer,
          $$SyncMetaTableOrderingComposer,
          $$SyncMetaTableAnnotationComposer,
          $$SyncMetaTableCreateCompanionBuilder,
          $$SyncMetaTableUpdateCompanionBuilder,
          (
            SyncMetaData,
            BaseReferences<_$AppDatabase, $SyncMetaTable, SyncMetaData>,
          ),
          SyncMetaData,
          PrefetchHooks Function()
        > {
  $$SyncMetaTableTableManager(_$AppDatabase db, $SyncMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<int> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => SyncMetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required int value,
            Value<int> rowid = const Value.absent(),
          }) => SyncMetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncMetaTable, SyncMetaData>(table),
                  BaseReferences<_$AppDatabase, $SyncMetaTable, SyncMetaData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncMetaTable,
      SyncMetaData,
      $$SyncMetaTableFilterComposer,
      $$SyncMetaTableOrderingComposer,
      $$SyncMetaTableAnnotationComposer,
      $$SyncMetaTableCreateCompanionBuilder,
      $$SyncMetaTableUpdateCompanionBuilder,
      (
        SyncMetaData,
        BaseReferences<_$AppDatabase, $SyncMetaTable, SyncMetaData>,
      ),
      SyncMetaData,
      PrefetchHooks Function()
    >;
typedef $$ExamsTableCreateCompanionBuilder = ExamsCompanion Function({
  required String id,
  required String bankId,
  required String title,
  required int finishedAt,
  required int total,
  required int correct,
  required int answered,
  required int percent,
  required bool passed,
  Value<int?> limitSec,
  required int usedMs,
  Value<String> deviceId,
  Value<String> itemsJson,
  Value<bool> synced,
  Value<int> rowid,
});
typedef $$ExamsTableUpdateCompanionBuilder = ExamsCompanion Function({
  Value<String> id,
  Value<String> bankId,
  Value<String> title,
  Value<int> finishedAt,
  Value<int> total,
  Value<int> correct,
  Value<int> answered,
  Value<int> percent,
  Value<bool> passed,
  Value<int?> limitSec,
  Value<int> usedMs,
  Value<String> deviceId,
  Value<String> itemsJson,
  Value<bool> synced,
  Value<int> rowid,
});

class $$ExamsTableFilterComposer extends Composer<_$AppDatabase, $ExamsTable> {
  $$ExamsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bankId => $composableBuilder(
    column: $table.bankId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get total => $composableBuilder(
    column: $table.total,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get correct => $composableBuilder(
    column: $table.correct,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get answered => $composableBuilder(
    column: $table.answered,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get passed => $composableBuilder(
    column: $table.passed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get limitSec => $composableBuilder(
    column: $table.limitSec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get usedMs => $composableBuilder(
    column: $table.usedMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemsJson => $composableBuilder(
    column: $table.itemsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ExamsTableOrderingComposer
    extends Composer<_$AppDatabase, $ExamsTable> {
  $$ExamsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bankId => $composableBuilder(
    column: $table.bankId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get total => $composableBuilder(
    column: $table.total,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get correct => $composableBuilder(
    column: $table.correct,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get answered => $composableBuilder(
    column: $table.answered,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get passed => $composableBuilder(
    column: $table.passed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get limitSec => $composableBuilder(
    column: $table.limitSec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get usedMs => $composableBuilder(
    column: $table.usedMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deviceId => $composableBuilder(
    column: $table.deviceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemsJson => $composableBuilder(
    column: $table.itemsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get synced => $composableBuilder(
    column: $table.synced,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ExamsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ExamsTable> {
  $$ExamsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get bankId =>
      $composableBuilder(column: $table.bankId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get total =>
      $composableBuilder(column: $table.total, builder: (column) => column);

  GeneratedColumn<int> get correct =>
      $composableBuilder(column: $table.correct, builder: (column) => column);

  GeneratedColumn<int> get answered =>
      $composableBuilder(column: $table.answered, builder: (column) => column);

  GeneratedColumn<int> get percent =>
      $composableBuilder(column: $table.percent, builder: (column) => column);

  GeneratedColumn<bool> get passed =>
      $composableBuilder(column: $table.passed, builder: (column) => column);

  GeneratedColumn<int> get limitSec =>
      $composableBuilder(column: $table.limitSec, builder: (column) => column);

  GeneratedColumn<int> get usedMs =>
      $composableBuilder(column: $table.usedMs, builder: (column) => column);

  GeneratedColumn<String> get deviceId =>
      $composableBuilder(column: $table.deviceId, builder: (column) => column);

  GeneratedColumn<String> get itemsJson =>
      $composableBuilder(column: $table.itemsJson, builder: (column) => column);

  GeneratedColumn<bool> get synced =>
      $composableBuilder(column: $table.synced, builder: (column) => column);
}

class $$ExamsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ExamsTable,
          ExamRow,
          $$ExamsTableFilterComposer,
          $$ExamsTableOrderingComposer,
          $$ExamsTableAnnotationComposer,
          $$ExamsTableCreateCompanionBuilder,
          $$ExamsTableUpdateCompanionBuilder,
          (ExamRow, BaseReferences<_$AppDatabase, $ExamsTable, ExamRow>),
          ExamRow,
          PrefetchHooks Function()
        > {
  $$ExamsTableTableManager(_$AppDatabase db, $ExamsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExamsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ExamsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExamsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> bankId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int> finishedAt = const Value.absent(),
                Value<int> total = const Value.absent(),
                Value<int> correct = const Value.absent(),
                Value<int> answered = const Value.absent(),
                Value<int> percent = const Value.absent(),
                Value<bool> passed = const Value.absent(),
                Value<int?> limitSec = const Value.absent(),
                Value<int> usedMs = const Value.absent(),
                Value<String> deviceId = const Value.absent(),
                Value<String> itemsJson = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ExamsCompanion(
                id: id,
                bankId: bankId,
                title: title,
                finishedAt: finishedAt,
                total: total,
                correct: correct,
                answered: answered,
                percent: percent,
                passed: passed,
                limitSec: limitSec,
                usedMs: usedMs,
                deviceId: deviceId,
                itemsJson: itemsJson,
                synced: synced,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String bankId,
                required String title,
                required int finishedAt,
                required int total,
                required int correct,
                required int answered,
                required int percent,
                required bool passed,
                Value<int?> limitSec = const Value.absent(),
                required int usedMs,
                Value<String> deviceId = const Value.absent(),
                Value<String> itemsJson = const Value.absent(),
                Value<bool> synced = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ExamsCompanion.insert(
                id: id,
                bankId: bankId,
                title: title,
                finishedAt: finishedAt,
                total: total,
                correct: correct,
                answered: answered,
                percent: percent,
                passed: passed,
                limitSec: limitSec,
                usedMs: usedMs,
                deviceId: deviceId,
                itemsJson: itemsJson,
                synced: synced,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ExamsTable, ExamRow>(table),
                  BaseReferences<_$AppDatabase, $ExamsTable, ExamRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ExamsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ExamsTable,
      ExamRow,
      $$ExamsTableFilterComposer,
      $$ExamsTableOrderingComposer,
      $$ExamsTableAnnotationComposer,
      $$ExamsTableCreateCompanionBuilder,
      $$ExamsTableUpdateCompanionBuilder,
      (ExamRow, BaseReferences<_$AppDatabase, $ExamsTable, ExamRow>),
      ExamRow,
      PrefetchHooks Function()
    >;
typedef $$ExamDraftsTableCreateCompanionBuilder = ExamDraftsCompanion Function({
  required String bankId,
  required String dataJson,
  required int savedAt,
  Value<int> rowid,
});
typedef $$ExamDraftsTableUpdateCompanionBuilder = ExamDraftsCompanion Function({
  Value<String> bankId,
  Value<String> dataJson,
  Value<int> savedAt,
  Value<int> rowid,
});

class $$ExamDraftsTableFilterComposer
    extends Composer<_$AppDatabase, $ExamDraftsTable> {
  $$ExamDraftsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get bankId => $composableBuilder(
    column: $table.bankId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ExamDraftsTableOrderingComposer
    extends Composer<_$AppDatabase, $ExamDraftsTable> {
  $$ExamDraftsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get bankId => $composableBuilder(
    column: $table.bankId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ExamDraftsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ExamDraftsTable> {
  $$ExamDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get bankId =>
      $composableBuilder(column: $table.bankId, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<int> get savedAt =>
      $composableBuilder(column: $table.savedAt, builder: (column) => column);
}

class $$ExamDraftsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ExamDraftsTable,
          ExamDraftRow,
          $$ExamDraftsTableFilterComposer,
          $$ExamDraftsTableOrderingComposer,
          $$ExamDraftsTableAnnotationComposer,
          $$ExamDraftsTableCreateCompanionBuilder,
          $$ExamDraftsTableUpdateCompanionBuilder,
          (
            ExamDraftRow,
            BaseReferences<_$AppDatabase, $ExamDraftsTable, ExamDraftRow>,
          ),
          ExamDraftRow,
          PrefetchHooks Function()
        > {
  $$ExamDraftsTableTableManager(_$AppDatabase db, $ExamDraftsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ExamDraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ExamDraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ExamDraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> bankId = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<int> savedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ExamDraftsCompanion(
                bankId: bankId,
                dataJson: dataJson,
                savedAt: savedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String bankId,
                required String dataJson,
                required int savedAt,
                Value<int> rowid = const Value.absent(),
              }) => ExamDraftsCompanion.insert(
                bankId: bankId,
                dataJson: dataJson,
                savedAt: savedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ExamDraftsTable, ExamDraftRow>(table),
                  BaseReferences<_$AppDatabase, $ExamDraftsTable, ExamDraftRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ExamDraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ExamDraftsTable,
      ExamDraftRow,
      $$ExamDraftsTableFilterComposer,
      $$ExamDraftsTableOrderingComposer,
      $$ExamDraftsTableAnnotationComposer,
      $$ExamDraftsTableCreateCompanionBuilder,
      $$ExamDraftsTableUpdateCompanionBuilder,
      (
        ExamDraftRow,
        BaseReferences<_$AppDatabase, $ExamDraftsTable, ExamDraftRow>,
      ),
      ExamDraftRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$BanksTableTableManager get banks =>
      $$BanksTableTableManager(_db, _db.banks);
  $$QuestionsTableTableManager get questions =>
      $$QuestionsTableTableManager(_db, _db.questions);
  $$AttemptsTableTableManager get attempts =>
      $$AttemptsTableTableManager(_db, _db.attempts);
  $$QuestionStatesTableTableManager get questionStates =>
      $$QuestionStatesTableTableManager(_db, _db.questionStates);
  $$PendingFlagsTableTableManager get pendingFlags =>
      $$PendingFlagsTableTableManager(_db, _db.pendingFlags);
  $$SyncMetaTableTableManager get syncMeta =>
      $$SyncMetaTableTableManager(_db, _db.syncMeta);
  $$ExamsTableTableManager get exams =>
      $$ExamsTableTableManager(_db, _db.exams);
  $$ExamDraftsTableTableManager get examDrafts =>
      $$ExamDraftsTableTableManager(_db, _db.examDrafts);
}
